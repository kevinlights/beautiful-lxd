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





