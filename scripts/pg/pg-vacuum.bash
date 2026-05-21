
# 进入数据库
docker exec -it patroni psql -U postgres -d index_test

-- 1. 创建测试表
DROP TABLE IF EXISTS vacuum_demo;
CREATE TABLE vacuum_demo (id INT, name TEXT);
INSERT INTO vacuum_demo SELECT i, 'user_' || i FROM generate_series(1, 10000) i;

-- 2. 查看表大小
SELECT pg_size_pretty(pg_total_relation_size('vacuum_demo')) as table_size;
#  table_size 
# ------------
#  472 kB
# (1 row)

-- 3. 查看死元组数量（初始为0）
SELECT n_dead_tup FROM pg_stat_user_tables WHERE relname = 'vacuum_demo';
#  n_dead_tup 
# ------------
#           0
# (1 row)

-- 4. 执行大量更新（产生死元组）
UPDATE vacuum_demo SET name = 'updated_' || id WHERE id % 2 = 0;
# UPDATE 5000

-- 5. 查看死元组（现在有很多）
SELECT n_dead_tup, n_live_tup FROM pg_stat_user_tables WHERE relname = 'vacuum_demo';
#  n_dead_tup | n_live_tup 
# ------------+------------
#        5000 |      10000
# (1 row)

-- 6. 执行 VACUUM
VACUUM vacuum_demo;
# VACUUM

-- 7. 死元组被清理了
SELECT n_dead_tup FROM pg_stat_user_tables WHERE relname = 'vacuum_demo';
#  n_dead_tup 
# ------------
#           0
# (1 row)

-- 8. 但是表大小没变（没有释放给操作系统）
SELECT pg_size_pretty(pg_total_relation_size('vacuum_demo')) as table_size;
#  table_size 
# ------------
#  728 kB
# (1 row)




### VACUUM FULL

-- 1. 创建并填充表
DROP TABLE IF EXISTS vacuum_test;
CREATE TABLE vacuum_test (id SERIAL, data TEXT);
INSERT INTO vacuum_test (data) SELECT md5(random()::text) FROM generate_series(1, 50000);

-- 2. 查看初始大小
SELECT 'initial' as stage, pg_size_pretty(pg_total_relation_size('vacuum_test')) as size;
#   stage  |  size   
# ---------+---------
#  initial | 3368 kB
# (1 row)

-- 3. 删除所有数据（产生大量死元组）
DELETE FROM vacuum_test;
# DELETE 50000

-- 4. 查看大小（表大小没变，还是那么大）
SELECT 'after_delete' as stage, pg_size_pretty(pg_total_relation_size('vacuum_test')) as size;
#     stage     |  size   
# --------------+---------
#  after_delete | 3368 kB
# (1 row)

-- 5. 执行普通 VACUUM（只是标记空间可重用，大小不变）
VACUUM vacuum_test;
SELECT 'after_vacuum' as stage, pg_size_pretty(pg_total_relation_size('vacuum_test')) as size;
#     stage     | size  
# --------------+-------
#  after_vacuum | 24 kB
# (1 row)

-- 6. 执行 VACUUM FULL（真正释放空间）
VACUUM FULL vacuum_test;
SELECT 'after_vacuum_full' as stage, pg_size_pretty(pg_total_relation_size('vacuum_test')) as size;
#        stage       |    size    
# -------------------+------------
#  after_vacuum_full | 8192 bytes
# (1 row)


### space reuse

-- 1. 重新填充表
TRUNCATE vacuum_test;
INSERT INTO vacuum_test (data) SELECT md5(random()::text) FROM generate_series(1, 50000);

-- 2. 查看当前表大小
SELECT pg_size_pretty(pg_total_relation_size('vacuum_test')) as size;
#   size   
# ---------
#  3368 kB
# (1 row)

-- 3. 删除一半数据
DELETE FROM vacuum_test WHERE id % 2 = 0;

-- 4. 查看大小（没变，还是 50000 行的空间）
SELECT pg_size_pretty(pg_total_relation_size('vacuum_test')) as size;
#   size   
# ---------
#  3376 kB
# (1 row)

-- 5. 执行 VACUUM（标记死元组可复用）
VACUUM vacuum_test;
#   size   
# ---------
#  3376 kB
# (1 row)

-- 6. 插入 25000 条新数据（会复用之前删除的空间，不会增加表大小）
INSERT INTO vacuum_test (data) SELECT md5(random()::text) FROM generate_series(1, 25000);

-- 7. 查看大小（可能没怎么增长，因为复用了空间）
SELECT pg_size_pretty(pg_total_relation_size('vacuum_test')) as size;
#   size   
# ---------
#  3376 kB
# (1 row)


-- 查看 AutoVacuum 是否开启
SHOW autovacuum;
#  autovacuum 
# ------------
#  on
# (1 row)


-- 查看 AutoVacuum 配置
SELECT name, setting, unit FROM pg_settings WHERE name LIKE 'autovacuum%';
#                  name                  |  setting  | unit 
# ---------------------------------------+-----------+------
#  autovacuum                            | on        | 
#  autovacuum_analyze_scale_factor       | 0.1       | 
#  autovacuum_analyze_threshold          | 50        | 
#  autovacuum_freeze_max_age             | 200000000 | 
#  autovacuum_max_workers                | 3         | 
#  autovacuum_multixact_freeze_max_age   | 400000000 | 
#  autovacuum_naptime                    | 60        | s
#  autovacuum_vacuum_cost_delay          | 2         | ms
#  autovacuum_vacuum_cost_limit          | -1        | 
#  autovacuum_vacuum_insert_scale_factor | 0.2       | 
#  autovacuum_vacuum_insert_threshold    | 1000      | 
#  autovacuum_vacuum_scale_factor        | 0.2       | 
#  autovacuum_vacuum_threshold           | 50        | 
#  autovacuum_work_mem                   | -1        | kB
# (14 rows)

# autovacuum_vacuum_threshold	50	死元组超过 50 个开始考虑
# autovacuum_vacuum_scale_factor	0.2	死元组超过表的 20% 开始考虑
# 实际触发	死元组 > 50 + 表行数 × 0.2	例如：1000行的表，死元组 > 250 时触发


-- 查看当前是否有 AutoVacuum 在运行
SELECT 
    pid,
    datname,
    query,
    state,
    now() - xact_start as duration
FROM pg_stat_activity 
WHERE query LIKE '%autovacuum%';

-- 查看 AutoVacuum 历史
SELECT 
    relname,
    last_vacuum,
    last_autovacuum,
    vacuum_count,
    autovacuum_count
FROM pg_stat_user_tables 
WHERE relname = 'vacuum_test';

# pid  |  datname   |               query                | state  | duration 
# ------+------------+------------------------------------+--------+----------
#  8827 | index_test | SELECT                            +| active | 00:00:00
#       |            |     pid,                          +|        | 
#       |            |     datname,                      +|        | 
#       |            |     query,                        +|        | 
#       |            |     state,                        +|        | 
#       |            |     now() - xact_start as duration+|        | 
#       |            | FROM pg_stat_activity             +|        | 
#       |            | WHERE query LIKE '%autovacuum%';   |        | 
# (1 row)

#    relname   |          last_vacuum          |        last_autovacuum        | vacuum_count | autovacuum_count 
# -------------+-------------------------------+-------------------------------+--------------+------------------
#  vacuum_test | 2026-05-20 18:04:18.538439+00 | 2026-05-20 18:05:03.485458+00 |            2 |                2




-- 创建表膨胀监控视图
CREATE OR REPLACE VIEW table_bloat AS
SELECT 
    schemaname,
    relname as tablename,           
    n_live_tup,
    n_dead_tup,
    round(100.0 * n_dead_tup / NULLIF(n_live_tup + n_dead_tup, 0), 2) as dead_tuple_percent,
    pg_size_pretty(pg_total_relation_size(schemaname||'.'||relname)) as total_size,
    last_vacuum,
    last_autovacuum
FROM pg_stat_user_tables
ORDER BY n_dead_tup DESC;

-- 先查看这个视图有哪些列
SELECT column_name, data_type 
FROM information_schema.columns 
WHERE table_name = 'pg_stat_user_tables';

-- 查看表膨胀情况
SELECT * FROM table_bloat WHERE dead_tuple_percent > 10;

-- 方式1：直接查询（不使用视图）
SELECT 
    schemaname,
    relname as table_name,
    n_live_tup,
    n_dead_tup,
    round(100.0 * n_dead_tup / NULLIF(n_live_tup + n_dead_tup, 0), 2) as dead_tuple_percent,
    pg_size_pretty(pg_total_relation_size(schemaname||'.'||relname)) as total_size,
    last_vacuum,
    last_autovacuum
FROM pg_stat_user_tables
ORDER BY n_dead_tup DESC;

# schemaname |    table_name    | n_live_tup | n_dead_tup | dead_tuple_percent | total_size |          last_vacuum          |        last_autovacuum        
# ------------+------------------+------------+------------+--------------------+------------+-------------------------------+-------------------------------
#  public     | index_comparison |     100000 |          0 |               0.00 | 24 MB      |                               | 2026-05-20 17:27:42.916906+00
#  public     | users_hash       |      50000 |          0 |               0.00 | 11 MB      |                               | 2026-05-20 16:34:42.039471+00
#  public     | logs_brin        |     500000 |          0 |               0.00 | 47 MB      |                               | 2026-05-20 17:22:43.031054+00
#  public     | stores_gist      |      10000 |          0 |               0.00 | 1496 kB    |                               | 2026-05-20 16:50:42.388477+00
#  public     | vacuum_test      |      50000 |          0 |               0.00 | 3344 kB    | 2026-05-20 18:04:18.538439+00 | 2026-05-20 18:05:03.485458+00
#  public     | vacuum_demo      |      10000 |          0 |               0.00 | 728 kB     | 2026-05-20 18:00:59.316929+00 | 2026-05-20 18:00:03.381446+00
#  public     | spatial_ref_sys  |       8500 |          0 |               0.00 | 7144 kB    |                               | 2026-05-20 16:50:42.319869+00
#  public     | articles_gin     |      50000 |          0 |               0.00 | 13 MB      |                               | 2026-05-20 17:11:42.666866+00
#  public     | orders_btree     |     100000 |          0 |               0.00 | 11 MB      |                               | 2026-05-20 16:32:41.998834+00
# (9 rows)

-- 方式2：查看特定表的膨胀情况
SELECT 
    relname,
    n_live_tup,
    n_dead_tup,
    round(100.0 * n_dead_tup / NULLIF(n_live_tup + n_dead_tup, 0), 2) as dead_ratio,
    pg_size_pretty(pg_total_relation_size(relname::regclass)) as total_size
FROM pg_stat_user_tables
WHERE relname = 'vacuum_demo';  -- 替换成你的表名

#    relname   | n_live_tup | n_dead_tup | dead_ratio | total_size 
# -------------+------------+------------+------------+------------
#  vacuum_demo |      10000 |          0 |       0.00 | 728 kB
# (1 row)




-- VACUUM FULL 会锁表
-- 在生产环境执行前，先查看表大小
SELECT pg_size_pretty(pg_total_relation_size('vacuum_test'));

-- 执行 VACUUM FULL（会锁表，业务会等待）
VACUUM FULL vacuum_test;

-- 更安全的方式：使用 pg_repack（不锁表）
-- 需要安装扩展：CREATE EXTENSION pg_repack;
-- 命令行：pg_repack -d database -t table_name