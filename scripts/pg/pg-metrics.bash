-- ============================================
-- 连接数监控
-- ============================================

-- 创建连接监控视图
DROP VIEW IF EXISTS connection_monitor;
CREATE VIEW connection_monitor AS
SELECT 
    'Total Connections' as metric,
    COUNT(*) as value,
    (SELECT setting::int FROM pg_settings WHERE name = 'max_connections') as max_allowed,
    round(100.0 * COUNT(*) / (SELECT setting::int FROM pg_settings WHERE name = 'max_connections'), 2) as usage_percent
FROM pg_stat_activity;

select * from connection_monitor;
#       metric       | value | max_allowed | usage_percent 
# -------------------+-------+-------------+---------------
#  Total Connections |    10 |         100 |         10.00
# (1 row)

-- 查看连接状态分布
SELECT 
    state,
    COUNT(*) as connection_count,
    round(100.0 * COUNT(*) / SUM(COUNT(*)) OVER(), 2) as percentage
FROM pg_stat_activity
GROUP BY state
ORDER BY connection_count DESC;

#  state  | connection_count | percentage 
# --------+------------------+------------
#         |                5 |      50.00
#  active |                3 |      30.00
#  idle   |                2 |      20.00
# (3 rows)

-- 查看活跃连接详情
SELECT 
    pid,
    usename,
    application_name,
    client_addr,
    state,
    now() - query_start as query_duration,
    left(query, 50) as query_preview
FROM pg_stat_activity
WHERE state = 'active' 
  AND pid != pg_backend_pid()
ORDER BY query_duration DESC
LIMIT 10;

#  pid |  usename   | application_name | client_addr | state  | query_duration  |                   query_preview                    
# -----+------------+------------------+-------------+--------+-----------------+----------------------------------------------------
#  118 | replicator | postgresql2      | 10.0.0.180  | active | 03:43:48.46835  | START_REPLICATION SLOT "postgresql2" 0/21000000 TI
#  120 | replicator | postgresql3      | 10.0.0.55   | active | 03:43:48.320252 | START_REPLICATION SLOT "postgresql3" 0/21000000 TI
# (2 rows)




-- ============================================
-- 缓存命中率监控
-- ============================================

-- 创建缓存命中率监控视图
DROP VIEW IF EXISTS cache_hit_monitor;
CREATE VIEW cache_hit_monitor AS
SELECT 
    datname,
    blks_hit,
    blks_read,
    round(100.0 * blks_hit / NULLIF(blks_read + blks_hit, 0), 2) as hit_ratio,
    CASE 
        WHEN round(100.0 * blks_hit / NULLIF(blks_read + blks_hit, 0), 2) < 90 THEN '⚠️ Low - Need Tuning'
        WHEN round(100.0 * blks_hit / NULLIF(blks_read + blks_hit, 0), 2) < 95 THEN '⚡ Normal'
        ELSE '✅ Excellent'
    END as status
FROM pg_stat_database
WHERE datname NOT IN ('template0', 'template1');

select * from cache_hit_monitor;
#   datname   | blks_hit | blks_read | hit_ratio |    status    
# ------------+----------+-----------+-----------+--------------
#  postgres   | 23644085 |   1558067 |     93.82 | ⚡ Normal
#  index_test |  3070646 |      1834 |     99.94 | ✅ Excellent
# (2 rows)

-- 查看当前配置
SELECT 
    name,
    setting,
    unit,
    context
FROM pg_settings 
WHERE name IN ('shared_buffers', 'effective_cache_size');
#          name         | setting | unit |  context   
# ----------------------+---------+------+------------
#  effective_cache_size | 524288  | 8kB  | user
#  shared_buffers       | 16384   | 8kB  | postmaster
# (2 rows)

-- 演示缓存效果
DROP TABLE IF EXISTS cache_demo;
CREATE TABLE cache_demo (id SERIAL, data TEXT);
INSERT INTO cache_demo (data) SELECT md5(random()::text) FROM generate_series(1, 10000);

-- 第一次查询（冷缓存，需要读磁盘）
EXPLAIN (ANALYZE, BUFFERS) SELECT COUNT(*) FROM cache_demo WHERE id < 5000;
-- 注意 Buffers: read 的数量
                                                    QUERY PLAN                                                    
# ------------------------------------------------------------------------------------------------------------------
#  Aggregate  (cost=226.24..226.25 rows=1 width=8) (actual time=2.723..2.724 rows=1 loops=1)
#    Buffers: shared hit=84
#    ->  Seq Scan on cache_demo  (cost=0.00..217.35 rows=3556 width=0) (actual time=0.028..1.789 rows=4999 loops=1)
#          Filter: (id < 5000)
#          Rows Removed by Filter: 5001
#          Buffers: shared hit=84
#  Planning:
#    Buffers: shared hit=6
#  Planning Time: 0.143 ms
#  Execution Time: 2.766 ms
# (10 rows)

-- 第二次查询（热缓存，命中共享缓冲区）
EXPLAIN (ANALYZE, BUFFERS) SELECT COUNT(*) FROM cache_demo WHERE id < 5000;
-- 注意 Buffers: hit 的数量增加，read 减少或为0
#                                                     QUERY PLAN                                                    
# ------------------------------------------------------------------------------------------------------------------
#  Aggregate  (cost=226.24..226.25 rows=1 width=8) (actual time=2.859..2.860 rows=1 loops=1)
#    Buffers: shared hit=84
#    ->  Seq Scan on cache_demo  (cost=0.00..217.35 rows=3556 width=0) (actual time=0.039..1.930 rows=4999 loops=1)
#          Filter: (id < 5000)
#          Rows Removed by Filter: 5001
#          Buffers: shared hit=84
#  Planning Time: 0.116 ms
#  Execution Time: 2.907 ms
# (8 rows)