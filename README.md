# emr64c_opt

## 项目简介

`emr64c_opt` 是面向 EMR / x86_64 大数据环境的系统级性能优化工具集，主要用于沉淀生产环境中的性能调优经验，覆盖 CPU、内存、NUMA、网络与内核参数优化等方向。

该项目目标是为大规模分布式计算系统提供一套可复用、可验证、可推广的性能优化基线方法。

## 核心能力

- CPU 亲和性与调度优化（affinity / cpuset）
- NUMA 感知调度与内存绑定优化（membind / interleave）
- 内核参数调优（sysctl / TCP / buffer / backlog）
- 网络软中断与收发路径优化（RPS / RFS / IRQ balance）
- 大数据运行时性能调优（JVM / Spark / Hive / Kafka）

## 典型场景

- 提升 Spark / Hive / Flink 等任务吞吐能力
- 降低 CPU sys / softirq 占比
- 优化高并发场景尾延迟（p95 / p99）
- 提升 NUMA 本地访问比例，减少跨节点访问开销
- 稳定高密度云主机性能表现

## 目录结构建议

```
configs/   # sysctl / NUMA / CPU 调优配置
scripts/   # 一键优化与回滚脚本
bench/     # 性能压测与验证方法
docs/      # 调优原理与经验总结
```

## 使用流程

1. 在测试环境选择对应业务负载模型（计算 / 存储 / 网络）
2. 应用 configs 或 scripts 中的优化策略
3. 使用 bench 进行性能对比验证
4. 监控关键指标（CPU steal、softirq、latency、throughput）
5. 分批灰度上线并持续观察稳定性

## 关键指标关注

- CPU steal 时间
- softirq 占比
- NUMA remote access ratio
- p95 / p99 延迟
- 吞吐量（QPS / jobs per hour）

## 注意事项

- 所有优化必须先在非生产环境验证
- 不同 workload 需要差异化策略，避免“一刀切”
- 部分优化可能提升局部指标但影响整体公平性
- 建议建立优化前后 baseline 对比体系

## 适用系统

- Hadoop / Spark / Hive / Flink
- Kafka / Pulsar 等消息系统
- 云原生高密度计算节点
- 分布式存储与计算集群

## 后续规划

- sysctl 标准参数库建设
- NUMA / CPU 调度自动化工具
- benchmark 自动化评估框架
- 可视化性能对比报告生成
