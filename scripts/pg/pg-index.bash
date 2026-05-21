lxc exec vm1 -- bash

# 你的查询是什么样的？
# │
# ├─ 等值查询 + 范围查询 + 排序
# │   └─ 用 B-Tree ✅
# │
# ├─ 只有精确等值，且不需要排序
# │   └─ 用 Hash（但 B-Tree 也能用，差别不大）
# │
# ├─ 地理位置/几何图形
# │   └─ 用 GiST ✅
# │
# ├─ 数组/JSON/全文检索
# │   └─ 用 GIN ✅
# │
# └─ 时序大表，按时间范围查
#     └─ 用 BRIN ✅（省空间）

# 创建专用测试数据库
docker exec patroni psql -U postgres -c "CREATE DATABASE index_test;"

# 切换到测试数据库
docker exec -it patroni psql -U postgres -d index_test


### B-Tree 索引示例

-- 创建订单表
DROP TABLE IF EXISTS orders_btree;
CREATE TABLE orders_btree (
    order_id SERIAL PRIMARY KEY,
    customer_name VARCHAR(100),
    order_amount DECIMAL(10,2),
    order_date DATE,
    status VARCHAR(20)
);

-- 插入 10 万条测试数据
INSERT INTO orders_btree (customer_name, order_amount, order_date, status)
SELECT 
    'Customer_' || (random() * 1000)::int,
    random() * 10000,
    NOW() - (random() * 365 || ' days')::interval,
    CASE WHEN random() < 0.8 THEN 'completed' ELSE 'pending' END
FROM generate_series(1, 100000);


-- 查看执行计划（全表扫描）
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM orders_btree WHERE order_amount BETWEEN 5000 AND 6000;

#                                                     QUERY PLAN                                                    
# ------------------------------------------------------------------------------------------------------------------
#  Seq Scan on orders_btree  (cost=0.00..1134.24 rows=100 width=300) (actual time=0.038..18.501 rows=10111 loops=1)
#    Filter: ((order_amount >= '5000'::numeric) AND (order_amount <= '6000'::numeric))
#    Rows Removed by Filter: 89889
#    Buffers: shared hit=834
#  Planning:
#    Buffers: shared hit=5
#  Planning Time: 0.319 ms
#  Execution Time: 19.185 ms
# (8 rows)


# Seq Scan on orders_btree	对表 orders_btree 进行顺序扫描。这是最基础的访问方式，逐行读取并检查条件。
# (cost=0.00..1134.24)	计划阶段预估的总成本：启动成本 0，扫描结束估计成本约1134.24。
# rows=100	规划阶段预估符合条件的返回行数：100行。但实际结果远超此数（10111行），说明统计信息严重不准。
# width=300	每一行返回数据的宽（字节），反映表实际列的总大小。
# (actual time=0.038..18.501)	执行时耗时范围：启动耗时约38µs，结束时刻耗18.501ms。括号内是启动 -> 结束的累计时间，不是单次扫描耗时（因为整个表只被扫描一次）。
# rows=10111 loops=1	实际返回了 10111 行数据，并行工作线程只用了 1 个（普通单遍扫描）。
# Filter: ... AND ...	过滤条件：order_amount 在 5000~6000 之间。
# Rows Removed by Filter: 89889	扫描期间被过滤掉（剔除）的行数：89,889行。这意味着实际扫描的总行数远高于 100，至少为 10111 + 89889 = 100,000 行（或更多，因为 rows=100 是估算）。
# Buffers: shared hit=834	共享缓冲区统计：共命中了 834次。说明表的大部分数据页已经缓存在内存中，扫描时无需从磁盘重新读入太多页。
# Planning: Buffers shared hit=5, Planning Time 0.319 ms	生成计划阶段的数据，本身不影响执行速度。
# Execution Time: 19.185 ms	查询实际执行总时间约19ms。相对于第二条计划的0.15ms，慢了超过120倍。


-- 创建 B-Tree 索引
CREATE INDEX idx_amount ON orders_btree USING btree (order_amount);

-- 查看索引大小
SELECT pg_size_pretty(pg_relation_size('idx_amount')) as index_size;
#  index_size 
# ------------
#  2208 kB
# (1 row)

-- 等值查询测试
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM orders_btree WHERE order_amount = 5000;

#                                                         QUERY PLAN                                                        
# --------------------------------------------------------------------------------------------------------------------------
#  Index Scan using idx_amount on orders_btree  (cost=0.29..8.31 rows=1 width=35) (actual time=0.114..0.114 rows=0 loops=1)
#    Index Cond: (order_amount = '5000'::numeric)
#    Buffers: shared read=2
#  Planning:
#    Buffers: shared hit=38
#  Planning Time: 0.880 ms
#  Execution Time: 0.150 ms
# (7 rows)


# Index Scan using idx_amount on orders_btree	使用索引 idx_amount（基于列 order_amount 的B-Tree）扫描表。这是直接定位访问方式，不是逐行扫描。
# (cost=0.29..8.31)	计划成本：启动约0.29，总成本约8.31（非常低）。
# rows=1	规划阶段预估符合条件的行数：只有1行。实际返回0行，说明表里根本没有 order_amount = 5000 的记录。
# width=35	返回的行宽度为35字节。这里 SELECT *，但实际只扫描了索引的列（因为后面没有堆表查找？）。如果查询需要所有列，还会有后续节点。宽度35远小于表的宽度（300），说明可能只查了索引覆盖的字段，或者后续节点被截断显示。
# (actual time=0.114..0.114)	执行时间非常短，启动和结束都在114µs内。说明查询几乎立刻完成。
# rows=0 loops=1	实际没有返回任何行。索引查找失败，但扫描过程依然进行了。
# Index Cond: (order_amount = '5000'::numeric)	索引上的查找条件：精确匹配 order_amount = 5000。这正好是B-Tree的最强优化场景（等值查询）。
# Buffers: shared read=2	只从磁盘读到 2个数据页。这通常意味着索引是1页（根/中间节点）+1页（叶子页），或者2个叶子页。 极少的I/O使得速度飞快。
# Planning: Buffers shared hit=38, Planning Time 0.880 ms	计划阶段统计，可忽略。
# Execution Time: 0.150 ms	总执行时间仅0.15ms。与第一条计划比，速度快近128倍。



-- 范围查询测试
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM orders_btree WHERE order_amount BETWEEN 5000 AND 6000;
#                                                          QUERY PLAN                                                          
# -----------------------------------------------------------------------------------------------------------------------------
#  Bitmap Heap Scan on orders_btree  (cost=215.79..1201.24 rows=10097 width=35) (actual time=1.735..4.264 rows=10111 loops=1)
#    Recheck Cond: ((order_amount >= '5000'::numeric) AND (order_amount <= '6000'::numeric))
#    Heap Blocks: exact=834
#    Buffers: shared hit=836 read=28
#    ->  Bitmap Index Scan on idx_amount  (cost=0.00..213.26 rows=10097 width=0) (actual time=1.615..1.616 rows=10111 loops=1)
#          Index Cond: ((order_amount >= '5000'::numeric) AND (order_amount <= '6000'::numeric))
#          Buffers: shared hit=2 read=28
#  Planning:
#    Buffers: shared hit=10
#  Planning Time: 0.348 ms
#  Execution Time: 4.793 ms
# (11 rows)

-- 排序查询测试
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM orders_btree ORDER BY order_amount LIMIT 10;
#                                                                QUERY PLAN                                                                
# -----------------------------------------------------------------------------------------------------------------------------------------
#  Limit  (cost=0.29..0.89 rows=10 width=35) (actual time=0.119..0.150 rows=10 loops=1)
#    Buffers: shared hit=11 read=1
#    ->  Index Scan using idx_amount on orders_btree  (cost=0.29..5940.05 rows=100000 width=35) (actual time=0.117..0.147 rows=10 loops=1)
#          Buffers: shared hit=11 read=1
#  Planning:
#    Buffers: shared hit=8
#  Planning Time: 0.183 ms
#  Execution Time: 0.182 ms
# (8 rows)





#### hash 索引示例



-- 创建用户表（用于精确查找）
DROP TABLE IF EXISTS users_hash;
CREATE TABLE users_hash (
    user_id SERIAL PRIMARY KEY,
    phone_number VARCHAR(20) UNIQUE,
    email VARCHAR(100),
    id_card VARCHAR(18)
);

-- 插入 5 万条测试数据
INSERT INTO users_hash (phone_number, email, id_card)
SELECT 
    '138' || LPAD(i::text, 8, '0'),
    'user' || i || '@example.com',
    LPAD(i::text, 18, '0')
FROM generate_series(1, 50000) i;

-- 创建 Hash 索引（只能用于 = 操作符）
CREATE INDEX idx_phone_hash ON users_hash USING hash (phone_number);

-- 对比：B-Tree 索引也可以做等值查询
CREATE INDEX idx_phone_btree ON users_hash USING btree (phone_number);

-- 查看索引大小对比
SELECT 
    indexname,
    pg_size_pretty(pg_relation_size(indexname::regclass)) as size
FROM pg_indexes 
WHERE tablename = 'users_hash' 
  AND indexname IN ('idx_phone_hash', 'idx_phone_btree');
#     indexname    |  size   
# -----------------+---------
#  idx_phone_hash  | 2336 kB
#  idx_phone_btree | 1552 kB
# (2 rows)

-- 等值查询（使用 Hash 索引）
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM users_hash WHERE phone_number = '13800000123';

#                                                          QUERY PLAN                                                         
# ----------------------------------------------------------------------------------------------------------------------------
#  Index Scan using idx_phone_hash on users_hash  (cost=0.00..8.02 rows=1 width=56) (actual time=0.091..0.093 rows=1 loops=1)
#    Index Cond: ((phone_number)::text = '13800000123'::text)
#    Buffers: shared hit=3
#  Planning:
#    Buffers: shared hit=43
#  Planning Time: 0.485 ms
#  Execution Time: 0.528 ms
# (7 rows)

-- Hash 索引不支持的操作（会走全表扫描）
-- 下面这个查询无法使用 Hash 索引
-- 也无法走 B-Tree 索引，字符串类型的范围查询不适合 B-Tree 索引
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM users_hash WHERE phone_number > '13800000000'; 
#                                                    QUERY PLAN                                                    
# -----------------------------------------------------------------------------------------------------------------
#  Seq Scan on users_hash  (cost=0.00..1183.00 rows=50000 width=56) (actual time=0.015..12.109 rows=50000 loops=1)
#    Filter: ((phone_number)::text > '13800000000'::text)
#    Buffers: shared hit=558
#  Planning:
#    Buffers: shared hit=11 read=2
#  Planning Time: 0.880 ms
#  Execution Time: 18.676 ms
# (7 rows)





### GiST 索示例


-- 如果系统安装了 PostGIS
CREATE EXTENSION IF NOT EXISTS postgis;

-- 如果没有，使用内置的几何类型

-- 创建地理信息表（商店位置）
DROP TABLE IF EXISTS stores_gist;
CREATE TABLE stores_gist (
    store_id SERIAL PRIMARY KEY,
    store_name VARCHAR(100),
    location POINT,           -- PostgreSQL 内置几何类型
    address TEXT
);

-- 插入 1 万个商店位置（随机经纬度）
INSERT INTO stores_gist (store_name, location)
SELECT 
    'Store_' || i,
    POINT(
        random() * 360 - 180,  -- 经度 -180 到 180
        random() * 180 - 90    -- 纬度 -90 到 90
    )
FROM generate_series(1, 10000) i;

-- 创建 GiST 索引（支持几何运算）
CREATE INDEX idx_location_gist ON stores_gist USING gist (location);

-- 查找距离某个点最近的前 5 个商店（使用 GiST 索引）
EXPLAIN (ANALYZE, BUFFERS)
SELECT 
    store_name,
    location <-> POINT(0, 0) as distance
FROM stores_gist
ORDER BY location <-> POINT(0, 0)
LIMIT 5;

#                                                                  QUERY PLAN                                                                  
# ---------------------------------------------------------------------------------------------------------------------------------------------
#  Limit  (cost=0.15..0.55 rows=5 width=226) (actual time=0.180..0.295 rows=5 loops=1)
#    Buffers: shared hit=4 read=5
#    ->  Index Scan using idx_location_gist on stores_gist  (cost=0.15..808.15 rows=10000 width=226) (actual time=0.179..0.292 rows=5 loops=1)
#          Order By: (location <-> '(0,0)'::point)
#          Buffers: shared hit=4 read=5
#  Planning:
#    Buffers: shared hit=34
#  Planning Time: 0.234 ms
#  Execution Time: 0.327 ms
# (9 rows)

-- 查找矩形范围内的商店
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM stores_gist
WHERE location <@ BOX(POINT(-10, -10), POINT(10, 10));
#                                                          QUERY PLAN                                                         
# ----------------------------------------------------------------------------------------------------------------------------
#  Bitmap Heap Scan on stores_gist  (cost=4.23..33.32 rows=10 width=62) (actual time=0.222..0.319 rows=56 loops=1)
#    Recheck Cond: (location <@ '(10,10),(-10,-10)'::box)
#    Heap Blocks: exact=37
#    Buffers: shared hit=43 read=1
#    ->  Bitmap Index Scan on idx_location_gist  (cost=0.00..4.23 rows=10 width=0) (actual time=0.207..0.207 rows=56 loops=1)
#          Index Cond: (location <@ '(10,10),(-10,-10)'::box)
#          Buffers: shared hit=6 read=1
#  Planning:
#    Buffers: shared hit=26 dirtied=1
#  Planning Time: 0.518 ms
#  Execution Time: 0.357 ms
# (11 rows)




### GIN 索引示例

-- 创建文章表（带标签数组）
DROP TABLE IF EXISTS articles_gin;
CREATE TABLE articles_gin (
    article_id SERIAL PRIMARY KEY,
    title TEXT,
    tags TEXT[],           -- 标签数组
    content TEXT,
    metadata JSONB         -- JSON 数据
);

-- 插入文章数据
INSERT INTO articles_gin (title, tags, content, metadata)
SELECT 
    'Article ' || i,
    ARRAY[
        'tag_' || (random() * 20)::int,
        'topic_' || (random() * 10)::int,
        CASE WHEN random() < 0.3 THEN 'important' ELSE 'normal' END
    ],
    'Content for article ' || i,
    jsonb_build_object(
        'author', 'author_' || (random() * 100)::int,
        'views', (random() * 10000)::int,
        'category', 'cat_' || (random() * 5)::int
    )
FROM generate_series(1, 50000) i;

-- 为数组创建 GIN 索引
CREATE INDEX idx_tags_gin ON articles_gin USING gin (tags);

-- 为 JSONB 创建 GIN 索引
CREATE INDEX idx_metadata_gin ON articles_gin USING gin (metadata);

-- 数组包含查询（查找同时包含两个标签的文章）
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM articles_gin 
WHERE tags @> ARRAY['tag_5', 'topic_2'];

#                                                         QUERY PLAN                                                        
# --------------------------------------------------------------------------------------------------------------------------
#  Bitmap Heap Scan on articles_gin  (cost=22.56..664.23 rows=261 width=170) (actual time=0.497..1.455 rows=240 loops=1)
#    Recheck Cond: (tags @> '{tag_5,topic_2}'::text[])
#    Heap Blocks: exact=218
#    Buffers: shared hit=223
#    ->  Bitmap Index Scan on idx_tags_gin  (cost=0.00..22.50 rows=261 width=0) (actual time=0.452..0.453 rows=240 loops=1)
#          Index Cond: (tags @> '{tag_5,topic_2}'::text[])
#          Buffers: shared hit=5
#  Planning:
#    Buffers: shared hit=55
#  Planning Time: 0.644 ms
#  Execution Time: 1.546 ms
# (11 rows)

-- 数组重叠查询（包含任意一个标签）
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM articles_gin 
WHERE tags && ARRAY['tag_10', 'tag_20'];
#                                                          QUERY PLAN                                                         
# ----------------------------------------------------------------------------------------------------------------------------
#  Bitmap Heap Scan on articles_gin  (cost=40.36..1336.00 rows=3651 width=170) (actual time=0.976..5.299 rows=3674 loops=1)
#    Recheck Cond: (tags && '{tag_10,tag_20}'::text[])
#    Heap Blocks: exact=1184
#    Buffers: shared hit=1188
#    ->  Bitmap Index Scan on idx_tags_gin  (cost=0.00..39.45 rows=3651 width=0) (actual time=0.735..0.735 rows=3674 loops=1)
#          Index Cond: (tags && '{tag_10,tag_20}'::text[])
#          Buffers: shared hit=4
#  Planning:
#    Buffers: shared hit=4
#  Planning Time: 0.241 ms
#  Execution Time: 5.567 ms
# (11 rows)

-- JSONB 查询（查找 metadata 中 author 为 author_5 的文章）
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM articles_gin 
WHERE metadata @> '{"author": "author_5"}';
#                                                           QUERY PLAN                                                           
# -------------------------------------------------------------------------------------------------------------------------------
#  Bitmap Heap Scan on articles_gin  (cost=26.82..1280.12 rows=1010 width=170) (actual time=0.429..2.209 rows=508 loops=1)
#    Recheck Cond: (metadata @> '{"author": "author_5"}'::jsonb)
#    Heap Blocks: exact=410
#    Buffers: shared hit=429
#    ->  Bitmap Index Scan on idx_metadata_gin  (cost=0.00..26.57 rows=1010 width=0) (actual time=0.375..0.375 rows=508 loops=1)
#          Index Cond: (metadata @> '{"author": "author_5"}'::jsonb)
#          Buffers: shared hit=19
#  Planning:
#    Buffers: shared hit=7
#  Planning Time: 0.246 ms
#  Execution Time: 2.280 ms
# (11 rows)

-- JSONB 路径查询（查找 views 超过 5000 的文章）
-- GIN 索引主要用于 @>、?、?&、?| 等操作符，不支持 > 比较
-- 需要对 (metadata->>'views')::int 这个表达式单独建索引
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM articles_gin 
WHERE (metadata->>'views')::int > 5000;
#                                                      QUERY PLAN                                                     
# --------------------------------------------------------------------------------------------------------------------
#  Seq Scan on articles_gin  (cost=0.00..2250.00 rows=16667 width=170) (actual time=0.022..17.399 rows=24894 loops=1)
#    Filter: (((metadata ->> 'views'::text))::integer > 5000)
#    Rows Removed by Filter: 25106
#    Buffers: shared hit=1250
#  Planning Time: 0.127 ms
#  Execution Time: 18.968 ms
# (6 rows)

-- 为 views 字段创建表达式索引
CREATE INDEX idx_views_expression ON articles_gin (((metadata->>'views')::int));

-- 现在查询会使用这个索引
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM articles_gin 
WHERE (metadata->>'views')::int > 5000;
#                                                               QUERY PLAN                                                               
# ---------------------------------------------------------------------------------------------------------------------------------------
#  Bitmap Heap Scan on articles_gin  (cost=229.46..1812.80 rows=16667 width=170) (actual time=3.611..12.518 rows=24894 loops=1)
#    Recheck Cond: (((metadata ->> 'views'::text))::integer > 5000)
#    Heap Blocks: exact=1250
#    Buffers: shared hit=1250 read=38
#    ->  Bitmap Index Scan on idx_views_expression  (cost=0.00..225.29 rows=16667 width=0) (actual time=3.458..3.458 rows=24894 loops=1)
#          Index Cond: (((metadata ->> 'views'::text))::integer > 5000)
#          Buffers: shared read=38
#  Planning:
#    Buffers: shared hit=21 read=1
#  Planning Time: 1.051 ms
#  Execution Time: 13.893 ms
# (11 rows)

SELECT pg_size_pretty(pg_relation_size('idx_views_expression')) as index_size;
#  index_size 
# ------------
#  592 kB
# (1 row)




### BRIN 索引示例

-- 创建日志表（时序数据，按时间顺序插入）
DROP TABLE IF EXISTS logs_brin;
CREATE TABLE logs_brin (
    log_id SERIAL,
    log_time TIMESTAMP DEFAULT NOW(),
    log_level VARCHAR(10),
    message TEXT,
    user_id INT
);

-- 插入 50 万条时序数据（按时间顺序）
INSERT INTO logs_brin (log_time, log_level, message, user_id)
SELECT 
    NOW() - (i || ' seconds')::interval,
    CASE WHEN random() < 0.1 THEN 'ERROR' WHEN random() < 0.3 THEN 'WARN' ELSE 'INFO' END,
    'Log message ' || i,
    (random() * 1000)::int
FROM generate_series(1, 500000) i;

-- 创建 B-Tree 索引
CREATE INDEX idx_btree_time ON logs_brin (log_time);

-- 创建 BRIN 索引（按块范围）
CREATE INDEX idx_brin_time ON logs_brin USING brin (log_time);

-- 查看索引大小对比
SELECT 
    indexname,
    pg_size_pretty(pg_relation_size(indexname::regclass)) as size
FROM pg_indexes 
WHERE tablename = 'logs_brin' 
  AND indexname IN ('idx_btree_time', 'idx_brin_time');
#     indexname    | size  
# ----------------+-------
#  idx_btree_time | 11 MB
#  idx_brin_time  | 24 kB
# (2 rows)

-- B-Tree 索引的查询计划
EXPLAIN (ANALYZE, BUFFERS)
SELECT COUNT(*) FROM logs_brin 
WHERE log_time > NOW() - interval '1 hour';
#                                                                  QUERY PLAN                                                                  
# ---------------------------------------------------------------------------------------------------------------------------------------------
#  Aggregate  (cost=110.41..110.42 rows=1 width=8) (actual time=0.497..0.498 rows=1 loops=1)
#    Buffers: shared hit=7 read=10
#    ->  Index Only Scan using idx_btree_time on logs_brin  (cost=0.43..101.66 rows=3499 width=0) (actual time=0.028..0.352 rows=3543 loops=1)
#          Index Cond: (log_time > (now() - '01:00:00'::interval))
#          Heap Fetches: 0
#          Buffers: shared hit=7 read=10
#  Planning:
#    Buffers: shared hit=35 read=3
#  Planning Time: 0.728 ms
#  Execution Time: 0.653 ms
# (10 rows)

-- BRIN 索引的查询计划（注意扫描的块数）
SET enable_indexscan = off;  -- 临时禁用 B-Tree
SET enable_bitmapscan = on;
EXPLAIN (ANALYZE, BUFFERS)
SELECT COUNT(*) FROM logs_brin 
WHERE log_time > NOW() - interval '1 hour';
#                                                              QUERY PLAN                                                             
# ------------------------------------------------------------------------------------------------------------------------------------
#  Aggregate  (cost=4931.10..4931.11 rows=1 width=8) (actual time=3.234..3.235 rows=1 loops=1)
#    Buffers: shared hit=133
#    ->  Bitmap Heap Scan on logs_brin  (cost=12.91..4922.40 rows=3480 width=0) (actual time=0.077..2.962 rows=3524 loops=1)
#          Recheck Cond: (log_time > (now() - '01:00:00'::interval))
#          Rows Removed by Index Recheck: 10181
#          Heap Blocks: lossy=128
#          Buffers: shared hit=133
#          ->  Bitmap Index Scan on idx_brin_time  (cost=0.00..12.04 rows=13514 width=0) (actual time=0.063..0.063 rows=1280 loops=1)
#                Index Cond: (log_time > (now() - '01:00:00'::interval))
#                Buffers: shared hit=5
#  Planning:
#    Buffers: shared hit=5
#  Planning Time: 0.464 ms
#  Execution Time: 3.292 ms
# (14 rows)





### 总结

-- ============================================
-- 所有索引类型对比测试
-- ============================================

-- 1. 创建各类型索引的测试表
DROP TABLE IF EXISTS index_comparison;
CREATE TABLE index_comparison (
    id SERIAL,
    exact_value INT,      -- 用于 B-Tree/Hash
    range_value INT,      -- 用于 B-Tree
    tags TEXT[],          -- 用于 GIN
    location POINT,       -- 用于 GiST
    created_at TIMESTAMP DEFAULT NOW()
);

-- 插入测试数据
INSERT INTO index_comparison (exact_value, range_value, tags, location)
SELECT 
    floor(random() * 10000)::int,
    floor(random() * 10000)::int,
    ARRAY['tag_' || floor(random() * 100)::int, 'type_' || floor(random() * 10)::int],
    POINT(random() * 360 - 180, random() * 180 - 90)
FROM generate_series(1, 100000);

-- 2. 创建所有类型索引
CREATE INDEX idx_btree_exact ON index_comparison USING btree (exact_value);
CREATE INDEX idx_btree_range ON index_comparison USING btree (range_value);
CREATE INDEX idx_hash_exact ON index_comparison USING hash (exact_value);
CREATE INDEX idx_gin_tags ON index_comparison USING gin (tags);
CREATE INDEX idx_gist_location ON index_comparison USING gist (location);
CREATE INDEX idx_brin_time ON index_comparison USING brin (created_at);

-- 3. 查看索引大小
SELECT 
    indexname,
    pg_size_pretty(pg_relation_size(indexname::regclass)) as size
FROM pg_indexes 
WHERE tablename = 'index_comparison'
ORDER BY pg_relation_size(indexname::regclass) DESC;

-- 4. 各类型查询测试
--  '=== B-Tree 等值查询 ==='
EXPLAIN (ANALYZE, BUFFERS, TIMING)
SELECT * FROM index_comparison WHERE exact_value = 5000;

--  '=== B-Tree 范围查询 ==='
EXPLAIN (ANALYZE, BUFFERS, TIMING)
SELECT * FROM index_comparison WHERE range_value BETWEEN 4000 AND 6000;

--  '=== Hash 等值查询 ==='
EXPLAIN (ANALYZE, BUFFERS, TIMING)
SELECT * FROM index_comparison WHERE exact_value = 5000;

--  '=== GIN 数组包含查询 ==='
EXPLAIN (ANALYZE, BUFFERS, TIMING)
SELECT COUNT(*) FROM index_comparison WHERE tags @> ARRAY['tag_50'];

--  '=== GiST 距离查询 ==='
EXPLAIN (ANALYZE, BUFFERS, TIMING)
SELECT * FROM index_comparison 
ORDER BY location <-> POINT(0, 0) 
LIMIT 5;

--  '=== BRIN 时间范围查询 ==='
EXPLAIN (ANALYZE, BUFFERS, TIMING)
SELECT COUNT(*) FROM index_comparison 
WHERE created_at > NOW() - interval '1 minute';