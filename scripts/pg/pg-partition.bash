-- ============================================
-- 范围分区：按日期分区
-- ============================================

-- 1. 创建分区主表
DROP TABLE IF EXISTS orders_range CASCADE;
CREATE TABLE orders_range (
    order_id SERIAL,
    order_date DATE NOT NULL,
    customer_id INT,
    amount DECIMAL(10,2),
    status VARCHAR(20)
) PARTITION BY RANGE (order_date);

-- 2. 创建分区（按季度）
CREATE TABLE orders_2024_q1 PARTITION OF orders_range
    FOR VALUES FROM ('2024-01-01') TO ('2024-04-01');

CREATE TABLE orders_2024_q2 PARTITION OF orders_range
    FOR VALUES FROM ('2024-04-01') TO ('2024-07-01');

CREATE TABLE orders_2024_q3 PARTITION OF orders_range
    FOR VALUES FROM ('2024-07-01') TO ('2024-10-01');

CREATE TABLE orders_2024_q4 PARTITION OF orders_range
    FOR VALUES FROM ('2024-10-01') TO ('2025-01-01');

-- 3. 插入测试数据
INSERT INTO orders_range (order_date, customer_id, amount, status)
SELECT 
    '2024-01-01'::date + (random() * 364)::int,
    (random() * 1000)::int,
    random() * 1000,
    CASE WHEN random() < 0.9 THEN 'completed' ELSE 'pending' END
FROM generate_series(1, 10000);

-- 4. 查看分区情况
SELECT 
    parent.relname as parent_table,
    child.relname as partition_name,
    pg_get_expr(child.relpartbound, child.oid) as partition_range
FROM pg_class parent
JOIN pg_inherits i ON parent.oid = i.inhparent
JOIN pg_class child ON child.oid = i.inhrelid
WHERE parent.relname = 'orders_range';

#  parent_table | partition_name |                 partition_range                  
# --------------+----------------+--------------------------------------------------
#  orders_range | orders_2024_q1 | FOR VALUES FROM ('2024-01-01') TO ('2024-04-01')
#  orders_range | orders_2024_q2 | FOR VALUES FROM ('2024-04-01') TO ('2024-07-01')
#  orders_range | orders_2024_q3 | FOR VALUES FROM ('2024-07-01') TO ('2024-10-01')
#  orders_range | orders_2024_q4 | FOR VALUES FROM ('2024-10-01') TO ('2025-01-01')
# (4 rows)

-- 5. 验证分区裁剪（只扫描相关分区）
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM orders_range 
WHERE order_date BETWEEN '2024-04-01' AND '2024-06-30';
-- 注意：只扫描 orders_2024_q2 分区
#                                                          QUERY PLAN                                                          
# -----------------------------------------------------------------------------------------------------------------------------
#  Seq Scan on orders_2024_q2 orders_range  (cost=0.00..56.74 rows=2516 width=27) (actual time=0.010..0.467 rows=2516 loops=1)
#    Filter: ((order_date >= '2024-04-01'::date) AND (order_date <= '2024-06-30'::date))
#    Buffers: shared hit=19
#  Planning:
#    Buffers: shared hit=73
#  Planning Time: 0.341 ms
#  Execution Time: 0.593 ms
# (7 rows)

-- 跨分区，会扫描多个相关分区
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM orders_range 
WHERE order_date BETWEEN '2024-04-01' AND '2025-06-30';
#                                                              QUERY PLAN                                                              
# -------------------------------------------------------------------------------------------------------------------------------------
#  Append  (cost=0.00..206.92 rows=7496 width=27) (actual time=0.016..3.246 rows=7496 loops=1)
#    Buffers: shared hit=57
#    ->  Seq Scan on orders_2024_q2 orders_range_1  (cost=0.00..56.74 rows=2516 width=27) (actual time=0.014..0.733 rows=2516 loops=1)
#          Filter: ((order_date >= '2024-04-01'::date) AND (order_date <= '2025-06-30'::date))
#          Buffers: shared hit=19
#    ->  Seq Scan on orders_2024_q3 orders_range_2  (cost=0.00..56.73 rows=2515 width=27) (actual time=0.013..0.812 rows=2515 loops=1)
#          Filter: ((order_date >= '2024-04-01'::date) AND (order_date <= '2025-06-30'::date))
#          Buffers: shared hit=19
#    ->  Seq Scan on orders_2024_q4 orders_range_3  (cost=0.00..55.98 rows=2465 width=27) (actual time=0.028..0.467 rows=2465 loops=1)
#          Filter: ((order_date >= '2024-04-01'::date) AND (order_date <= '2025-06-30'::date))
#          Buffers: shared hit=19
#  Planning:
#    Buffers: shared hit=57
#  Planning Time: 0.602 ms
#  Execution Time: 3.875 ms
# (15 rows)

-- 6. 查看各分区数据量
SELECT 
    tableoid::regclass as partition_name,
    COUNT(*) as row_count
FROM orders_range
GROUP BY tableoid
ORDER BY partition_name;

#  partition_name | row_count 
# ----------------+-----------
#  orders_2024_q1 |      2504
#  orders_2024_q2 |      2516
#  orders_2024_q3 |      2515
#  orders_2024_q4 |      2465
# (4 rows)





-- ============================================
-- 列表分区：按地区分区
-- ============================================

-- 1. 创建分区主表
DROP TABLE IF EXISTS users_list CASCADE;
CREATE TABLE users_list (
    user_id SERIAL,
    username VARCHAR(50),
    region VARCHAR(20),
    created_at TIMESTAMP DEFAULT NOW()
) PARTITION BY LIST (region);

-- 2. 创建分区（按地区）
CREATE TABLE users_north PARTITION OF users_list
    FOR VALUES IN ('north', 'northern');

CREATE TABLE users_south PARTITION OF users_list
    FOR VALUES IN ('south', 'southern');

CREATE TABLE users_east PARTITION OF users_list
    FOR VALUES IN ('east', 'eastern');

CREATE TABLE users_west PARTITION OF users_list
    FOR VALUES IN ('west', 'western');

CREATE TABLE users_other PARTITION OF users_list
    DEFAULT;  -- 默认分区，存放未匹配的数据

-- 3. 插入测试数据
INSERT INTO users_list (username, region)
SELECT 
    'user_' || i,
    CASE (random() * 5)::int
        WHEN 0 THEN 'north'
        WHEN 1 THEN 'south'
        WHEN 2 THEN 'east'
        WHEN 3 THEN 'west'
        ELSE 'unknown'
    END
FROM generate_series(1, 10000) i;

-- 4. 验证分区裁剪
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM users_list WHERE region = 'north';
-- 只扫描 users_north 分区
#                                                       QUERY PLAN                                                      
# ----------------------------------------------------------------------------------------------------------------------
#  Seq Scan on users_north users_list  (cost=0.00..14.62 rows=2 width=188) (actual time=0.021..0.449 rows=1062 loops=1)
#    Filter: ((region)::text = 'north'::text)
#    Buffers: shared hit=8
#  Planning:
#    Buffers: shared hit=20
#  Planning Time: 0.216 ms
#  Execution Time: 0.523 ms
# (7 rows)

-- 5. 查看各分区分布
SELECT 
    tableoid::regclass as partition,
    COUNT(*) as user_count
FROM users_list
GROUP BY tableoid
ORDER BY user_count DESC;

#   partition  | user_count 
# -------------+------------
#  users_other |       2941
#  users_west  |       2059
#  users_south |       2017
#  users_east  |       1921
#  users_north |       1062
# (5 rows)





-- ============================================
-- 哈希分区：按用户ID均匀分布
-- ============================================

-- 1. 创建分区主表
DROP TABLE IF EXISTS logs_hash CASCADE;
CREATE TABLE logs_hash (
    log_id SERIAL,
    user_id INT,
    log_time TIMESTAMP DEFAULT NOW(),
    action VARCHAR(50),
    details TEXT
) PARTITION BY HASH (user_id);

-- 2. 创建4个分区（均匀分布）
CREATE TABLE logs_hash_0 PARTITION OF logs_hash
    FOR VALUES WITH (MODULUS 4, REMAINDER 0);

CREATE TABLE logs_hash_1 PARTITION OF logs_hash
    FOR VALUES WITH (MODULUS 4, REMAINDER 1);

CREATE TABLE logs_hash_2 PARTITION OF logs_hash
    FOR VALUES WITH (MODULUS 4, REMAINDER 2);

CREATE TABLE logs_hash_3 PARTITION OF logs_hash
    FOR VALUES WITH (MODULUS 4, REMAINDER 3);

-- 3. 插入测试数据
INSERT INTO logs_hash (user_id, action)
SELECT 
    (random() * 10000)::int,
    'action_' || (random() * 10)::int
FROM generate_series(1, 50000);

-- 4. 查看数据分布是否均匀
SELECT 
    tableoid::regclass as partition,
    COUNT(*) as row_count,
    round(100.0 * COUNT(*) / 50000, 2) as percentage
FROM logs_hash
GROUP BY tableoid
ORDER BY partition;
#   partition  | row_count | percentage 
# -------------+-----------+------------
#  logs_hash_0 |     12403 |      24.81
#  logs_hash_1 |     12738 |      25.48
#  logs_hash_2 |     12652 |      25.30
#  logs_hash_3 |     12207 |      24.41
# (4 rows)

-- 5. 哈希分区对特定用户查询的优势
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM logs_hash WHERE user_id = 1234;
-- 直接定位到特定分区

                                                    QUERY PLAN                                                    
# ------------------------------------------------------------------------------------------------------------------
#  Seq Scan on logs_hash_2 logs_hash  (cost=0.00..252.15 rows=5 width=57) (actual time=0.076..0.890 rows=6 loops=1)
#    Filter: (user_id = 1234)
#    Rows Removed by Filter: 12646
#    Buffers: shared hit=94
#  Planning:
#    Buffers: shared hit=28
#  Planning Time: 0.941 ms
#  Execution Time: 0.908 ms
# (8 rows)


