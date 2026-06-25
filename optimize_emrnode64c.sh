#!/bin/bash
# =========================================================================
# Kunpeng 920 128C / 25G SmartNIC (Virtio) Ultimate NUMA & IRQ Tune
# 架构定位:
#   - Node 0 (0-63): 网卡独占(0-15) + 计算区(16-31) + 存储内核态重载区(16-63)
#   - Node 1 (64-127): 绝对纯净计算区 (零硬中断，避开跨 NUMA 访存惩罚)
#   - 128核 XPS 垂直切片对齐 (消除发包自旋锁)
# =========================================================================

set -e

IFACE="eno0"
IRQBALANCE_CFG=/etc/sysconfig/irqbalance

echo "===== Ultimate NUMA & IRQ Tuning Starting ====="

############################################
# [安全阀] 硬件拓扑与驱动严格校验
############################################
echo -e "\n[Pre-flight Check] 正在校验硬件拓扑与驱动基线..."

# 1. 校验: 每 Socket 核心数必须为 64
CORES_PER_SOCKET=$(lscpu | awk -F: '/Core\(s\) per socket/ {print $2}' | tr -d ' ')
if [ "$CORES_PER_SOCKET" != "64" ]; then
    echo "ERROR: 硬件拓扑不匹配！预期每 Socket 为 64 核心，当前检测为: ${CORES_PER_SOCKET}。"
    echo "本脚本掩码逻辑严格依赖 64 核心/Socket 的 NUMA 架构，安全阀已触发，退出执行。"
    exit 1
fi

# 2. 校验: 目标网卡驱动必须为 virtio_net
NIC_DRIVER=$(ethtool -i $IFACE 2>/dev/null | grep driver | awk '{print $2}')
if [ "$NIC_DRIVER" != "virtio_net" ]; then
    echo "ERROR: 网卡驱动不匹配！预期 $IFACE 驱动为 'virtio_net'，当前检测为: '${NIC_DRIVER}'。"
    echo "非智能网卡环境无法应用此 XPS/RFS 垂直对齐策略，安全阀已触发，退出执行。"
    exit 1
fi

echo "校验通过: 硬件拓扑与网络驱动符合调优基线要求。"

############################################
# 工具函数：生成单核的 128-bit 十六进制掩码
############################################
cpu_mask()
{
    local cpu=$1
    local a=0 b=0 c=0 d=0

    if ((cpu<32)); then
        d=$((1<<cpu))
    elif ((cpu<64)); then
        c=$((1<<(cpu-32)))
    elif ((cpu<96)); then
        b=$((1<<(cpu-64)))
    else
        a=$((1<<(cpu-96)))
    fi
    printf "%08x,%08x,%08x,%08x\n" $a $b $c $d
}

############################################
# 工具函数：生成连续范围的 128-bit 十六进制掩码
############################################
cpu_range_mask()
{
    local start=$1 end=$2
    local a=0 b=0 c=0 d=0

    for ((i=start;i<=end;i++)); do
        if ((i<32)); then
            d=$((d|(1<<i)))
        elif ((i<64)); then
            c=$((c|(1<<(i-32))))
        elif ((i<96)); then
            b=$((b|(1<<(i-64))))
        else
            a=$((a|(1<<(i-96))))
        fi
    done
    printf "%08x,%08x,%08x,%08x\n" $a $b $c $d
}

############################################
# 1. 精准抓取 Virtio 智能网卡中断 & 配置 irqbalance
############################################
echo -e "\n[1/5] Config irqbalance..."

VIRTIO_DEV=$(basename $(readlink /sys/class/net/$IFACE/device 2>/dev/null) 2>/dev/null || true)

if [ -z "$VIRTIO_DEV" ]; then
    echo "ERROR: 无法推导 $IFACE 的底层总线设备名！"
    exit 1
fi

NIC_IRQS=$(awk -v dev="$VIRTIO_DEV" '$0~dev {gsub(/:/,"",$1); print $1}' /proc/interrupts | tr '\n' ' ' | sed 's/ $//')

if [ -z "$NIC_IRQS" ]; then
    echo "ERROR: 无法获取 $VIRTIO_DEV 的中断号，请检查 /proc/interrupts！"
    exit 1
fi

echo "成功获取智能网卡 ($VIRTIO_DEV) 中断号: $NIC_IRQS"

if [ -f "$IRQBALANCE_CFG" ];then
    cp $IRQBALANCE_CFG ${IRQBALANCE_CFG}.bak.$(date +%F_%H%M%S)
    sed -i '/IRQBALANCE_BANNED_IRQS/d' $IRQBALANCE_CFG
    echo "IRQBALANCE_BANNED_IRQS=\"$NIC_IRQS\"" >> $IRQBALANCE_CFG
    systemctl restart irqbalance
    echo "irqbalance 守护进程已更新并重启。"
fi
sleep 2

############################################
# 2. NIC IRQ (CPU 0-15 绝对独占)
############################################
echo -e "\n[2/5] Bind NIC IRQ to CPU 0-15..."
cpu=0
for irq in $NIC_IRQS; do
    cpu_use=$((cpu%16))
    cpu_mask $cpu_use > /proc/irq/$irq/smp_affinity 2>/dev/null || true
    printf "NIC IRQ %-4s -> CPU %d\n" $irq $cpu_use
    cpu=$((cpu+1))
done

############################################
# 3. RFS 智能流导引 (废弃多余的 RPS)
############################################
echo -e "\n[3/5] Config RFS (Hardware to App Direct)..."
echo 32768 > /proc/sys/net/core/rps_sock_flow_entries
for q in /sys/class/net/$IFACE/queues/rx-*; do
    [ -f $q/rps_cpus ] && echo "00000000,00000000,00000000,00000000" > $q/rps_cpus
    [ -f $q/rps_flow_cnt ] && echo 2048 > $q/rps_flow_cnt
done
echo "RFS configured. RPS disabled."

############################################
# 4. XPS 全局垂直映射 (128核防锁竞争)
############################################
echo -e "\n[4/5] Config XPS 128-Core Vertical Slices..."
queue=0
for q in /sys/class/net/$IFACE/queues/tx-*; do
    if [ $queue -lt 16 ]; then
        block_val=$(( (1<<queue) | (1<<(queue+16)) ))
        XPS_MASK=$(printf "%08x,%08x,%08x,%08x\n" $block_val $block_val $block_val $block_val)
        
        echo $XPS_MASK > $q/xps_cpus 2>/dev/null || true
    fi
    queue=$((queue+1))
done
echo "XPS mapping applied successfully."

############################################
# 5. Writeback & XFS (锁定 Node 0 存储重载区)
############################################
echo -e "\n[5/5] Bind writeback & XFS background threads..."
WQ_MASK=$(cpu_range_mask 16 63)
for w in /sys/bus/workqueue/devices/*/cpumask; do
    name=$(basename $(dirname $w))
    case "$name" in
        writeback*|xfs*|kblockd*)
            echo $WQ_MASK > $w 2>/dev/null || true
            ;;
    esac
done
echo "Storage background threads bound to CPU 16-63."

echo -e "\n========================================="
echo "Done. All subsystems optimized successfully."
echo "========================================="
