## PostgreSQL 系统内置表/视图总览表

### 表1：统计信息视图

| 视图名称 | 中文含义 | 主要字段 | 使用场景 |
|----------|----------|----------|----------|
| `pg_stat_activity` | 连接活动状态 | `pid`, `usename`, `state`, `query`, `query_start` | 查看当前连接、终止异常连接、监控慢查询 |
| `pg_stat_database` | 数据库级统计 | `datname`, `numbackends`, `blks_hit`, `blks_read`, `xact_commit` | 计算缓存命中率、监控事务负载 |
| `pg_stat_user_tables` | 用户表统计 | `relname`, `seq_scan`, `n_live_tup`, `n_dead_tup`, `last_vacuum` | 监控表膨胀、找出需要VACUUM的表 |
| `pg_stat_user_indexes` | 用户索引统计 | `indexrelname`, `idx_scan`, `idx_tup_read`, `idx_tup_fetch` | 找出未使用索引、分析索引效率 |
| `pg_stat_replication` | 流复制状态 | `application_name`, `state`, `sync_state`, `replay_lag`, `replay_lsn` | 监控主从复制延迟、检查从库健康状态 |
| `pg_stat_statements` | SQL性能统计 | `query`, `calls`, `mean_exec_time`, `total_exec_time`, `rows` | 分析最慢SQL、找出高频查询 |

### 表2：系统目录表

| 视图/表名称 | 中文含义 | 主要字段 | 使用场景 |
|-------------|----------|----------|----------|
| `pg_class` | 对象元数据 | `relname`, `relpages`, `reltuples`, `relkind`, `oid` | 查看表/索引大小、获取对象OID |
| `pg_indexes` | 索引定义 | `schemaname`, `tablename`, `indexname`, `indexdef` | 查看索引创建语句、查找表达式索引 |
| `pg_settings` | 配置参数 | `name`, `setting`, `unit`, `context`, `boot_val` | 查看PostgreSQL配置、参数调优 |
| `pg_inherits` | 继承关系 | `inhparent`, `inhrelid` | 查看分区表的子表列表 |

### 表3：锁与并发视图

| 视图名称 | 中文含义 | 主要字段 | 使用场景 |
|----------|----------|----------|----------|
| `pg_locks` | 锁信息 | `locktype`, `pid`, `mode`, `granted`, `relation` | 分析锁等待、找出阻塞源头 |

---

## 按使用频率分类

### 高频使用（每天/实时）

| 视图 | 使用频率 | 典型监控项 |
|------|----------|------------|
| `pg_stat_activity` | 实时监控 | 连接数、慢查询、死锁 |
| `pg_stat_replication` | 每10秒 | 复制延迟、从库状态 |
| `pg_stat_database` | 每5分钟 | 缓存命中率、TPS |

### 中频使用（每小时/每天）

| 视图 | 使用频率 | 典型监控项 |
|------|----------|------------|
| `pg_stat_user_tables` | 每小时 | 表膨胀、死元组数量 |
| `pg_class` | 每天 | 表大小增长趋势 |
| `pg_settings` | 每次部署 | 配置参数检查 |

### 低频使用（每周/按需）

| 视图 | 使用频率 | 典型监控项 |
|------|----------|------------|
| `pg_stat_user_indexes` | 每周 | 未使用索引清理 |
| `pg_stat_statements` | 按需 | SQL性能分析 |
| `pg_locks` | 出问题时 | 锁等待排查 |
| `pg_indexes` | 按需 | 查询索引定义 |
| `pg_inherits` | 按需 | 分区表结构查看 |

---

## 按功能分类

### 性能监控类

| 视图 | 监控指标 | 告警阈值 |
|------|----------|----------|
| `pg_stat_database` | 缓存命中率 | < 95% |
| `pg_stat_activity` | 活跃连接数 | > 100 |
| `pg_stat_activity` | 慢查询时长 | > 1秒 |
| `pg_stat_statements` | 平均查询耗时 | > 100ms |

### 容量监控类

| 视图 | 监控指标 | 告警阈值 |
|------|----------|----------|
| `pg_class` | 表大小 | > 100GB |
| `pg_stat_user_tables` | 死元组比例 | > 10% |
| `pg_class` | 索引大小 | > 50GB |

### 高可用监控类

| 视图 | 监控指标 | 告警阈值 |
|------|----------|----------|
| `pg_stat_replication` | 复制延迟 | > 10秒 |
| `pg_stat_replication` | 从库状态 | state ≠ 'streaming' |

### 锁监控类

| 视图 | 监控指标 | 告警阈值 |
|------|----------|----------|
| `pg_locks` | 等待锁数量 | > 0 |
| `pg_locks` | 锁等待时长 | > 5秒 |

---

## 快速查询SQL汇总

```sql
-- 1. 缓存命中率
SELECT datname, 
       round(100.0 * blks_hit / (blks_hit + blks_read), 2) as hit_rate
FROM pg_stat_database;

-- 2. 表膨胀（死元组）
SELECT relname, n_live_tup, n_dead_tup,
       round(100.0 * n_dead_tup / nullif(n_live_tup, 0), 2) as dead_ratio
FROM pg_stat_user_tables
WHERE n_dead_tup > 1000;

-- 3. 未使用索引
SELECT schemaname, tablename, indexrelname, idx_scan
FROM pg_stat_user_indexes
WHERE idx_scan = 0;

-- 4. 复制延迟
SELECT application_name, sync_state, replay_lag
FROM pg_stat_replication;

-- 5. 当前活跃连接
SELECT state, COUNT(*) FROM pg_stat_activity GROUP BY state;

-- 6. 慢查询（运行中）
SELECT pid, now() - query_start as duration, query
FROM pg_stat_activity
WHERE state = 'active' AND now() - query_start > interval '1 second';

-- 7. 表大小
SELECT relname, pg_size_pretty(pg_relation_size(oid)) as size
FROM pg_class 
WHERE relkind = 'r' 
ORDER BY pg_relation_size(oid) DESC 
LIMIT 10;

-- 8. 锁等待
SELECT pid, granted, mode FROM pg_locks WHERE NOT granted;
```

---

## 记忆口诀

```
活动连接看 activity
性能指标看 database
表膨胀看 user_tables
复制延迟看 replication
没用索引看 user_indexes
慢SQL 看 statements
表大小看 class
配置参数看 settings
锁等待看 locks
分区继承看 inherits
```