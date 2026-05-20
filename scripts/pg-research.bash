lxc exec vm1 -- bash

docker exec -it patroni bash
docker exec -it patroni ps aux | grep postgres
# postgres      28  0.0  0.2 219448  8992 ?        Ss   13:50   0:00 postgres: postgres: checkpointer 
# postgres      29  0.0  0.2 219464  7692 ?        Ss   13:50   0:00 postgres: postgres: background writer 
# postgres      36  0.0  0.5 222308 18108 ?        Ss   13:50   0:00 postgres: postgres: postgres postgres 10.0.0.219(46960) idle
# postgres      38  0.0  0.5 221992 17664 ?        Ss   13:50   0:01 postgres: postgres: postgres postgres 10.0.0.219(46974) idle
# postgres      45  0.0  0.3 219328 10632 ?        Ss   13:50   0:00 postgres: postgres: walwriter 
# postgres      46  0.0  0.2 220924  9572 ?        Ss   13:50   0:00 postgres: postgres: autovacuum launcher 
# postgres      47  0.0  0.2 220908  8884 ?        Ss   13:50   0:00 postgres: postgres: logical replication launcher 
# postgres      54  0.0  0.3 221204 12204 ?        Ss   13:50   0:00 postgres: postgres: walsender replicator 10.0.0.55(56940) streaming 0/200001B8
# postgres      55  0.0  0.3 221204 12208 ?        Ss   13:50   0:00 postgres: postgres: walsender replicator 10.0.0.180(52260) streaming 0/200001B8

for i in {1..3}; do
  docker exec patroni psql -U postgres -c "SELECT pg_backend_pid(), pg_sleep(60);" &
done

# postgres      26  0.0  0.2 219448 10096 ?        Ss   14:43   0:00 postgres: postgres: checkpointer 
# postgres      27  0.0  0.2 219464  7704 ?        Ss   14:43   0:00 postgres: postgres: background writer 
# postgres      37  0.0  0.5 222488 19428 ?        Ss   14:43   0:00 postgres: postgres: postgres postgres 10.0.0.219(57050) idle
# postgres      41  0.0  0.5 221764 17692 ?        Ss   14:43   0:00 postgres: postgres: postgres postgres 10.0.0.219(57058) idle
# postgres     106  0.0  0.3 219328 10624 ?        Ss   14:44   0:00 postgres: postgres: walwriter 
# postgres     107  0.0  0.2 220924  9556 ?        Ss   14:44   0:00 postgres: postgres: autovacuum launcher 
# postgres     108  0.0  0.2 220908  8884 ?        Ss   14:44   0:00 postgres: postgres: logical replication launcher 
# postgres     118  0.0  0.3 221464 12532 ?        Ss   14:44   0:00 postgres: postgres: walsender replicator 10.0.0.180(40526) streaming 0/210F4F50
# postgres     120  0.0  0.3 221464 12528 ?        Ss   14:44   0:00 postgres: postgres: walsender replicator 10.0.0.55(52076) streaming 0/210F4F50
# postgres     894  0.0  0.4 221324 15208 ?        Ss   15:01   0:00 postgres: postgres: postgres postgres [local] SELECT
# postgres     895  0.0  0.4 221324 15208 ?        Ss   15:01   0:00 postgres: postgres: postgres postgres [local] SELECT
# postgres     896  0.0  0.4 221324 15216 ?        Ss   15:01   0:00 postgres: postgres: postgres postgres [local] SELECT

# shared memory segments
docker exec patroni bash -c "ipcs -m"
# ------ Shared Memory Segments --------
# key        shmid      owner      perms      bytes      nattch     status      
# 0x002e604d 1          postgres   600        56         10        

ocker exec patroni psql -U postgres -c "SHOW shared_buffers;"
#  shared_buffers 
# ----------------
#  128MB
# (1 row)

docker exec patroni bash -c "cat /proc/sysvipc/shm"
#        key      shmid perms                  size  cpid  lpid nattch   uid   gid  cuid  cgid      atime      dtime      ctime                   rss                  swap
#    3039309          1   600                    56    26  1778     10   101   103   101   103 1779286975 1779286975 1779285023                  4096                     0

docker exec patroni psql -U postgres -c "
SELECT 
  datname,
  blks_hit::float / (blks_read + blks_hit) * 100 as cache_hit_ratio
FROM pg_stat_database
WHERE datname = 'postgres';
"
#  datname  |  cache_hit_ratio  
# ----------+-------------------
#  postgres | 97.39104654610139
# (1 row)


# MVCC
docker exec patroni psql -U postgres -c "
CREATE TABLE test_mvcc (id INT PRIMARY KEY, name TEXT);
INSERT INTO test_mvcc VALUES (1, 'Alice'), (2, 'Bob');
SELECT 
  relname,
  relfilenode,
  pg_relation_filepath(oid)
FROM pg_class 
WHERE relname = 'test_mvcc';
"
# CREATE TABLE
# INSERT 0 2
#   relname  | relfilenode | pg_relation_filepath 
# -----------+-------------+----------------------
#  test_mvcc |       24583 | base/5/24583
# (1 row)

docker exec patroni bash -c "ls -la /data/postgresql/base/*/*" | head -20

docker exec -it patroni psql -U postgres -c "
BEGIN;
UPDATE test_mvcc SET name = 'Alice_Updated' WHERE id = 1;
SELECT *, xmin, xmax FROM test_mvcc;
"

# 终端 A：开启事务，更新但不提交
docker exec -it patroni psql -U postgres -c "
BEGIN;
UPDATE test_mvcc SET name = 'Alice_Updated' WHERE id = 1;
SELECT *, xmin, xmax FROM test_mvcc;
"
# 保持事务开启，不要执行 COMMIT
# BEGIN
# UPDATE 1
#  id |     name      | xmin | xmax 
# ----+---------------+------+------
#   2 | Bob           |  735 |    0
#   1 | Alice_Updated |  736 |    0
# (2 rows)


# 终端 B：查询同一数据（应该看到旧版本）
docker exec patroni psql -U postgres -c "SELECT *, xmin, xmax FROM test_mvcc WHERE id = 1;"
# 预期输出：name 仍为 'Alice'（未提交的修改不可见）
#  id | name  | xmin | xmax 
# ----+-------+------+------
#   1 | Alice |  735 |  736
# (1 row)

docker exec patroni psql -U postgres -c "
SELECT 
  relname,
  n_live_tup as live_tuples,
  n_dead_tup as dead_tuples,
  last_vacuum,
  last_autovacuum
FROM pg_stat_user_tables
WHERE relname = 'test_mvcc';
"

# 查看表和死元组信息
docker exec patroni psql -U postgres -c "
SELECT 
  relname,
  n_live_tup as live_tuples,
  n_dead_tup as dead_tuples,
  last_vacuum,
  last_autovacuum
FROM pg_stat_user_tables
WHERE relname = 'test_mvcc';
"

#   relname  | live_tuples | dead_tuples | last_vacuum | last_autovacuum 
# -----------+-------------+-------------+-------------+-----------------
#  test_mvcc |           2 |           1 |             | 
# (1 row)


# 执行更新产生死元组
docker exec patroni psql -U postgres -c "
UPDATE test_mvcc SET name = 'Bob_Updated' WHERE id = 2;
UPDATE test_mvcc SET name = 'Bob_Updated2' WHERE id = 2;
"

# 再次查看死元组数量（应该增加了）
docker exec patroni psql -U postgres -c "
SELECT n_live_tup, n_dead_tup FROM pg_stat_user_tables WHERE relname = 'test_mvcc';
"
#  n_live_tup | n_dead_tup 
# ------------+------------
#           2 |          3
# (1 row)

# 1. 查看 WAL 配置
docker exec patroni psql -U postgres -c "SHOW wal_level;"
#  wal_level 
# -----------
#  replica
# (1 row)
docker exec patroni psql -U postgres -c "SHOW wal_keep_size;"
#  wal_keep_size 
# ---------------
#  128MB
# (1 row)

# 2. 查看 WAL 文件位置和大小
docker exec patroni bash -c "ls -la /data/postgresql/pg_wal/ | head -10"

# 3. 查看当前 WAL 位置
docker exec patroni psql -U postgres -c "SELECT pg_current_wal_lsn();"
#  pg_current_wal_lsn 
# --------------------
#  0/20059148
# (1 row)

# 4. 手动切换 WAL 文件
docker exec patroni psql -U postgres -c "SELECT pg_switch_wal();"
#  pg_switch_wal 
# ---------------
#  0/20059160
# (1 row)

# 5. 查看 WAL 归档状态（如果配置了）
docker exec patroni psql -U postgres -c "SELECT * FROM pg_stat_archiver;"
#  archived_count | last_archived_wal | last_archived_time | failed_count | last_failed_wal | last_failed_time |          stats_reset          
# ----------------+-------------------+--------------------+--------------+-----------------+------------------+-------------------------------
#               0 |                   |                    |            0 |                 |                  | 2026-05-20 13:50:23.804938+00
# (1 row)


# HA
# 在主节点上执行
docker exec patroni psql -U postgres -c "
SELECT 
  application_name,
  state,
  sync_state,
  sync_priority,
  replay_lag,
  flush_lag
FROM pg_stat_replication;
"
#  application_name |   state   | sync_state | sync_priority | replay_lag | flush_lag 
# ------------------+-----------+------------+---------------+------------+-----------
#  postgresql2      | streaming | async      |             0 |            | 
#  postgresql3      | streaming | async      |             0 |            | 
# (2 rows)

# 在主节点写入大量数据，观察延迟
docker exec patroni psql -U postgres -c "
CREATE TABLE test_replication (id SERIAL, data TEXT);
INSERT INTO test_replication (data) SELECT generate_series(1,10000)::text;
"

# 查看复制延迟
docker exec patroni psql -U postgres -c "
SELECT 
  application_name,
  write_lag,
  flush_lag,
  replay_lag
FROM pg_stat_replication;
"

# CREATE TABLE
# INSERT 0 10000
#  application_name |    write_lag    |    flush_lag    |   replay_lag    
# ------------------+-----------------+-----------------+-----------------
#  postgresql2      | 00:00:00.000336 | 00:00:00.001778 | 00:00:00.004369
#  postgresql3      | 00:00:00.001011 | 00:00:00.002037 | 00:00:00.005366
# (2 rows)

# 在 vm2 上执行
docker exec patroni psql -U postgres -c "SELECT COUNT(*) FROM test_replication;"
# 应该与主节点数量一致
# 应该与主节点数量一致
#  count 
# -------
#  10000
# (1 row)


# sync and async replication
# 查看 synchronous_commit 设置
docker exec patroni psql -U postgres -c "SHOW synchronous_commit;"
# 默认通常是 on（主库等待从库确认）
#  synchronous_commit 
# --------------------
#  on
# (1 row)

# 查看同步备用节点配置
docker exec patroni psql -U postgres -c "SHOW synchronous_standby_names;"
# ---------------------------
 
# (1 row)

# 配置同步复制（至少一个从库同步确认）
# 在 vm1（主节点）上修改 Patroni 配置
# cat > /data/patroni/patroni.yml << 'EOF'
# # ... 前面配置保持不变，修改 postgresql 部分 ...
# postgresql:
#   parameters:
#     synchronous_commit: "on"
#     synchronous_standby_names: "FIRST 1 (postgresql3)"  # 指定同步副本
# EOF

# # 重启 Patroni 使配置生效
# docker restart patroni

# # 验证配置
# docker exec patroni psql -U postgres -c "SHOW synchronous_standby_names;"
# # 应该输出: FIRST 1 (postgresql3)


watch -n 2 'docker exec patroni patronictl -c /etc/patroni/patroni.yml list'

# 终端 2：停止当前主节点（假设 vm1 是 Leader）
# 注意：不要在生产环境执行！
docker stop patroni  # 停止 vm1 上的 Patroni

# 观察终端 1 的变化：
# - 约 10-30 秒后，原主节点状态变为 failed
# - 其中一个从节点被提升为新的 Leader


# 重新启动原主节点
docker start patroni

# 等待恢复，它会自动作为 Replica 加入集群
watch -n 2 'docker exec patroni patronictl list'

# 将原主节点重新提升为 Leader
docker exec patroni patronictl -c /etc/patroni/patroni.yml switchover --candidate postgresql1 --force
# Current cluster topology
# + Cluster: postgres (7641951170765574165) -------+----+-----------+
# | Member      | Host       | Role    | State     | TL | Lag in MB |
# +-------------+------------+---------+-----------+----+-----------+
# | postgresql1 | 10.0.0.219 | Replica | streaming |  7 |         0 |
# | postgresql2 | 10.0.0.180 | Replica | streaming |  7 |         0 |
# | postgresql3 | 10.0.0.55  | Leader  | running   |  7 |           |
# +-------------+------------+---------+-----------+----+-----------+
# 2026-05-20 14:44:10.31907 Successfully switched over to "postgresql1"
# + Cluster: postgres (7641951170765574165) -------+----+-----------+
# | Member      | Host       | Role    | State     | TL | Lag in MB |
# +-------------+------------+---------+-----------+----+-----------+
# | postgresql1 | 10.0.0.219 | Leader  | running   |  7 |           |
# | postgresql2 | 10.0.0.180 | Replica | streaming |  7 |         0 |
# | postgresql3 | 10.0.0.55  | Replica | stopped   |    |   unknown |
# +-------------+------------+---------+-----------+----+-----------+


# verify haproxy write and read
# 查看 HAProxy 配置
cat /data/haproxy/haproxy.cfg | grep -A 10 "listen primary"
cat /data/haproxy/haproxy.cfg | grep -A 10 "listen replica"

# listen primary
#     bind *:5000
#     option httpchk OPTIONS /master
#     http-check expect status 200
#     default-server inter 3s fall 3 rise 2 on-marked-down shutdown-sessions
#     server pg1 10.0.0.219:5432 maxconn 100 check port 8008
#     server pg2 10.0.0.180:5432 maxconn 100 check port 8008
#     server pg3 10.0.0.55:5432 maxconn 100 check port 8008

# listen replica
#     bind *:5001
# listen replica
#     bind *:5001
#     option httpchk OPTIONS /replica
#     http-check expect status 200
#     default-server inter 3s fall 3 rise 2 on-marked-down shutdown-sessions
#     server pg1 10.0.0.219:5432 maxconn 100 check port 8008
#     server pg2 10.0.0.180:5432 maxconn 100 check port 8008
#     server pg3 10.0.0.55:5432 maxconn 100 check port 8008

nc -v 127.0.0.1 5000
nc -v 127.0.0.1 5001

apt install -y postgresql-client
psql --version

# exec psql without password prompt
export PGPASSWORD="super-pass"
# 通过 HAProxy 的 5000 端口（主库入口）写入
psql -h 127.0.0.1 -p 5000 -U postgres -c "
CREATE TABLE test_haproxy (id SERIAL, source TEXT);
INSERT INTO test_haproxy (source) VALUES ('via_primary_port');
"

# INSERT 0 1

# 验证数据在哪个节点
for node in 10.0.0.219 10.0.0.180 10.0.0.55; do
  echo "=== Node $node ==="
  psql -h $node -p 5432 -U postgres -c "SELECT COUNT(*) FROM test_haproxy;"
done
# 所有节点应该都有相同数据
# === Node 10.0.0.219 ===
#  count 
# -------
#      1
# (1 row)

# === Node 10.0.0.180 ===
#  count 
# -------
#      1
# (1 row)

# === Node 10.0.0.55 ===
#  count 
# -------
#      1
# (1 row)

# 通过 HAProxy 的 5001 端口（从库入口）多次查询
for i in {1..10}; do
  psql -h 127.0.0.1 -p 5001 -U postgres -t -c "SELECT inet_server_addr();"
done | sort | uniq -c

# 预期输出类似（请求被分发到不同的从节点）：
    #  10 
    #   7  10.0.0.180
    #   3  10.0.0.55

# curl http://192.168.64.3:7000