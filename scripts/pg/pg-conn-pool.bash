-- ============================================
-- 连接池效果模拟演示
-- ============================================

-- 1. 查看当前连接数
SELECT 
    datname,
    numbackends as current_connections,
    setting::int as max_allowed
FROM pg_stat_database 
JOIN pg_settings ON name = 'max_connections'
WHERE datname = 'postgres';

#  datname  | current_connections | max_allowed 
# ----------+---------------------+-------------
#  postgres |                   2 |         100

-- 2. 模拟大量连接（无连接池的情况）
-- 创建临时函数来演示连接开销
CREATE OR REPLACE FUNCTION simulate_connection_heavy()
RETURNS VOID AS $$
DECLARE
    i INT;
    conn_count INT;
BEGIN
    FOR i IN 1..100 LOOP
        -- 模拟连接开销
        PERFORM pg_sleep(0.01);
        conn_count := (
            SELECT COUNT(*) 
            FROM pg_stat_activity 
            WHERE datname = 'postgres'
        );
        RAISE NOTICE 'Connection count: %', conn_count;
    END LOOP;
END;
$$ LANGUAGE plpgsql;

-- 3. 查看当前活动连接详情
SELECT 
    pid,
    usename,
    application_name,
    state,
    now() - backend_start as connection_duration,
    query
FROM pg_stat_activity 
WHERE datname = 'postgres' 
  AND pid != pg_backend_pid()
ORDER BY connection_duration DESC;

