# =============================================================================
# lib/kb.sh — Knowledge base of findings: category, recommendation and vendor
# reference for every check the collectors can raise. Centralizing this text
# keeps recommendations consistent and makes it easy to update wording as
# vendor guidance evolves, without touching collection logic.
# =============================================================================

declare -A KB_CAT=()
declare -A KB_REC=()
declare -A KB_REF=()

kb() { # kb KEY CATEGORY RECOMMENDATION REFERENCE
  KB_CAT["$1"]="$2"; KB_REC["$1"]="$3"; KB_REF["$1"]="$4"
}

# ── System / OS ──────────────────────────────────────────────────────────
kb sys.cpu_load "CPU" \
  "Investigate top CPU consumers (ps/top), check for runnable-queue saturation with 'vmstat 1', and consider CPU affinity/cgroup limits or horizontal scaling if load is sustained rather than a transient spike." \
  "Red Hat — Monitoring and Managing System Status and Performance: https://access.redhat.com/documentation/en-us/red_hat_enterprise_linux/9/html/monitoring_and_managing_system_status_and_performance/"

kb sys.memory_high "Memory" \
  "Confirm this is real pressure and not cache (check MemAvailable vs MemFree). If genuine, identify top consumers, review OOM-killer history, and evaluate resizing or workload placement." \
  "Red Hat — Analyzing and Managing Memory: https://access.redhat.com/documentation/en-us/red_hat_enterprise_linux/9/html/monitoring_and_managing_system_status_and_performance/analyzing-system-performance-with-free_monitoring-and-managing-system-status-and-performance"

kb sys.swap_high "Memory" \
  "Sustained swap usage indicates memory pressure. Review vm.swappiness for the workload (databases typically want 1-10) and validate whether more RAM or workload tuning is required." \
  "Kernel.org — Documentation/admin-guide/sysctl/vm.rst: https://www.kernel.org/doc/html/latest/admin-guide/sysctl/vm.html"

kb sys.disk_high "Storage" \
  "Disk usage above 85% risks application failures and blocks log rotation / DB writes. Identify large/old files, rotate or archive logs, and plan capacity expansion." \
  "Red Hat — Managing Storage Devices: https://access.redhat.com/documentation/en-us/red_hat_enterprise_linux/9/html/managing_storage_devices/"

kb sys.disk_inodes "Storage" \
  "Inode exhaustion causes 'No space left on device' even with free bytes. Locate directories with excessive small files (mail queues, session/cache dirs, log spam) and clean or restructure them." \
  "Red Hat — Managing File Systems: https://access.redhat.com/documentation/en-us/red_hat_enterprise_linux/9/html/managing_file_systems/"

kb sys.net_timewait "Network" \
  "A very large TIME_WAIT count can exhaust ephemeral ports under high connection churn. Consider net.ipv4.tcp_tw_reuse, connection pooling/keep-alive on the application side, and reviewing net.ipv4.ip_local_port_range." \
  "Kernel.org — ip-sysctl.txt (TCP tuning): https://www.kernel.org/doc/Documentation/networking/ip-sysctl.txt"

kb sys.fd_limit "Kernel Limits" \
  "File descriptor usage close to fs.file-max or per-process ulimit -n risks 'too many open files' errors under load. Raise limits deliberately (systemd LimitNOFILE / limits.conf) sized to the workload, and confirm the running service actually adopted the new limit." \
  "Red Hat — Setting limits for applications: https://access.redhat.com/solutions/61334"

kb sys.zombie "Processes" \
  "Zombie processes indicate a parent is not reaping children (wait()). This is usually an application/init bug; identify the parent PID and review its process-reaping logic or supervisor (systemd/tini/s6)." \
  "man 2 wait / systemd service reaping semantics"

kb sys.oom "Processes" \
  "OOM-killer activity means the kernel had to forcibly reclaim memory, killing a process. Review the killed process, memory cgroup limits, and whether swap/RAM sizing matches the workload's peak footprint." \
  "Red Hat — Out of Memory management: https://access.redhat.com/documentation/en-us/red_hat_enterprise_linux/9/html/monitoring_and_managing_system_status_and_performance/"

kb sys.pending_reboot "Patching" \
  "A pending reboot means kernel/library updates are staged but not active — the running system may still carry patched vulnerabilities in memory. Schedule a maintenance window to reboot." \
  "Red Hat — needs-restarting(1); Debian — /var/run/reboot-required; SUSE — zypper ps -s"

kb sys.security_updates "Patching" \
  "Outstanding security updates leave known CVEs unpatched. Schedule patching per your change-management process, prioritizing kernel and network-facing services." \
  "Red Hat/CentOS: dnf/yum updateinfo · SUSE: zypper list-patches · Debian/Ubuntu: unattended-upgrades / apt list --upgradable"

kb sys.mac_disabled "Security" \
  "Mandatory Access Control (SELinux/AppArmor) is disabled or permissive. This removes a defense-in-depth layer against process/container breakout. Re-enable enforcing mode after validating policy in a staging environment." \
  "Red Hat — SELinux User's and Administrator's Guide: https://access.redhat.com/documentation/en-us/red_hat_enterprise_linux/9/html/using_selinux/ · Ubuntu — AppArmor: https://ubuntu.com/server/docs/security-apparmor"

kb sys.firewall "Security" \
  "No active host firewall was detected. Even behind network security groups, a host-level firewall (firewalld/ufw/nftables) provides defense in depth." \
  "Red Hat — Using firewalld: https://access.redhat.com/documentation/en-us/red_hat_enterprise_linux/9/html/configuring_firewalls_and_packet_filters/ · Ubuntu — UFW: https://ubuntu.com/server/docs/security-firewall"

kb sys.ntp "Reliability" \
  "Clock is not synchronized. Time drift breaks TLS validation, distributed consensus (etcd/Kafka/DB replication), Kerberos auth, and makes log correlation unreliable." \
  "Red Hat — Configuring time synchronization: https://access.redhat.com/documentation/en-us/red_hat_enterprise_linux/9/html/configuring_basic_system_settings/"

kb sys.thp "Memory" \
  "Transparent Huge Pages can cause latency spikes and CPU overhead for database workloads (MySQL/MongoDB/Redis all recommend disabling THP or defrag=never)." \
  "Red Hat — Removing Transparent Huge Pages: https://access.redhat.com/solutions/46111 · MongoDB Production Notes: https://www.mongodb.com/docs/manual/administration/production-notes/"

# ── Web / Proxy ──────────────────────────────────────────────────────────
kb nginx.stub_status "Observability" \
  "Enable the stub_status (or ngx_http_api) module so live connection/request metrics can be scraped for capacity planning and alerting." \
  "NGINX Docs — Module ngx_http_stub_status_module: https://nginx.org/en/docs/http/ngx_http_stub_status_module.html"

kb nginx.errors "Web Server" \
  "A high error/crit/emerg count in the NGINX error log usually points to upstream failures, config issues, or resource exhaustion. Review recent entries and correlate with upstream health." \
  "NGINX Docs — Troubleshooting: https://docs.nginx.com/nginx/admin-guide/monitoring/troubleshooting-guide/"

kb apache.status "Observability" \
  "Enable mod_status (server-status) to expose worker/thread utilization for capacity planning." \
  "Apache HTTP Server Docs — mod_status: https://httpd.apache.org/docs/2.4/mod/mod_status.html"

kb haproxy.socket "Observability" \
  "The HAProxy admin/stats socket is not reachable. Configure a 'stats socket' in haproxy.cfg to allow read-only runtime metrics collection without exposing the stats page publicly." \
  "HAProxy Docs — Management Guide (Unix Socket commands): https://www.haproxy.org/download/2.8/doc/management.txt"

kb varnish.generic "Web Cache" \
  "Review varnishstat cache hit ratio and thread pool saturation; a low hit ratio often traces back to overly aggressive Vary/Cookie handling in VCL." \
  "Varnish Docs — Achieving a High Hitrate: https://docs.varnish-software.com/tutorials/increasing-your-hitrate/"

# ── Databases ─────────────────────────────────────────────────────────────
kb mysql.buffer_pool "Database" \
  "InnoDB buffer pool hit rate below ~99% causes excessive physical I/O. Size innodb_buffer_pool_size to ~60-75% of available RAM on a dedicated DB host (workload dependent) and re-evaluate." \
  "MySQL 8.0 Reference Manual — InnoDB Buffer Pool: https://dev.mysql.com/doc/refman/8.0/en/innodb-buffer-pool.html"

kb mysql.connections "Database" \
  "Connection usage approaching max_connections risks refused connections. Investigate connection leaks/pooling on the application side before simply raising the limit, since each connection reserves memory." \
  "MySQL 8.0 Reference Manual — Connection Management: https://dev.mysql.com/doc/refman/8.0/en/connection-interfaces.html"

kb mysql.slowlog "Database" \
  "Slow query log is disabled, hiding queries that hurt latency and lock contention. Enable it with a threshold appropriate to the SLA and review via pt-query-digest or mysqldumpslow." \
  "MySQL 8.0 Reference Manual — The Slow Query Log: https://dev.mysql.com/doc/refman/8.0/en/slow-query-log.html"

kb postgresql.cache_hit "Database" \
  "Shared buffer cache hit ratio below ~99% suggests shared_buffers/effective_cache_size may be undersized for the working set, or queries are scanning more data than necessary." \
  "PostgreSQL Docs — Resource Consumption: https://www.postgresql.org/docs/current/runtime-config-resource.html"

kb postgresql.idx_scan "Database" \
  "Tables with a high proportion of sequential scans relative to index scans may be missing useful indexes, or the planner is choosing seq scans due to stale statistics — check ANALYZE freshness." \
  "PostgreSQL Docs — Query Planning / pg_stat_user_tables: https://www.postgresql.org/docs/current/monitoring-stats.html"

kb postgresql.autovacuum "Database" \
  "High dead-tuple counts relative to live tuples indicate autovacuum is not keeping up, leading to table/index bloat and slower scans." \
  "PostgreSQL Docs — Routine Vacuuming: https://www.postgresql.org/docs/current/routine-vacuuming.html"

kb postgresql.locks "Database" \
  "Blocking lock chains were detected. Sustained blocking increases latency and can cascade into connection pool exhaustion; identify the blocking query and consider statement_timeout / lock_timeout." \
  "PostgreSQL Docs — Explicit Locking: https://www.postgresql.org/docs/current/explicit-locking.html"

kb redis.hitrate "Cache" \
  "A cache hit rate below ~80% reduces the benefit of caching and pushes load to the backing store. Review key expiration policy, cache warming, and whether maxmemory-policy fits the access pattern." \
  "Redis Docs — Memory Optimization: https://redis.io/docs/latest/operate/rs/references/memory-optimization/"

kb redis.maxmemory "Cache" \
  "No maxmemory / eviction policy is configured, risking unbounded memory growth and OOM on a shared host." \
  "Redis Docs — Eviction Policies: https://redis.io/docs/latest/develop/reference/eviction/"

kb redis.persistence "Cache" \
  "Review RDB/AOF persistence settings against the durability requirements — an unpersisted cache used as a source of truth risks data loss on restart." \
  "Redis Docs — Persistence: https://redis.io/docs/latest/operate/oss_and_stack/management/persistence/"

kb mongodb.generic "Database" \
  "Review serverStatus/db.stats() output for connection saturation, WiredTiger cache pressure, and replication lag against MongoDB production guidance." \
  "MongoDB — Production Notes: https://www.mongodb.com/docs/manual/administration/production-notes/"

kb elasticsearch.cluster_health "Search/Analytics" \
  "Cluster health is not green (yellow/red), indicating unassigned or relocating shards. Investigate node capacity, disk watermark thresholds, and shard allocation." \
  "Elastic Docs — Cluster Health API: https://www.elastic.co/guide/en/elasticsearch/reference/current/cluster-health.html"

kb elasticsearch.heap "Search/Analytics" \
  "JVM heap for Elasticsearch should generally be set to ~50% of system RAM and never exceed ~32GB (to keep compressed OOPs). Review -Xms/-Xmx alignment and heap pressure." \
  "Elastic Docs — Heap size settings: https://www.elastic.co/guide/en/elasticsearch/reference/current/important-settings.html#heap-size-settings"

kb memcached.generic "Cache" \
  "Review eviction/miss counters — frequent evictions relative to memory size suggest the allocated cache is undersized for the working set." \
  "Memcached Wiki — Programming Techniques: https://github.com/memcached/memcached/wiki"

kb rabbitmq.generic "Message Queue" \
  "Review queue depth, consumer counts, and memory/disk alarms — growing unconsumed queues indicate a consumer bottleneck or downstream outage." \
  "RabbitMQ Docs — Production Checklist: https://www.rabbitmq.com/docs/production-checklist"

kb kafka.generic "Message Queue" \
  "Review under-replicated partitions and consumer lag — both are leading indicators of broker or consumer-side capacity problems." \
  "Apache Kafka — Operations: https://kafka.apache.org/documentation/#operations"

# ── App runtimes ─────────────────────────────────────────────────────────
kb nodejs.generic "Application Runtime" \
  "Review per-process RSS trend and event-loop saturation; a single Node.js process only uses one core by default, so CPU-bound workloads may need clustering (PM2/cluster module)." \
  "Node.js Docs — Diagnostics: https://nodejs.org/en/docs/guides/diagnostics/"

kb phpfpm.status "Observability" \
  "Enable the FPM status page (pm.status_path) to expose pool utilization (active/idle/queue) for capacity planning." \
  "PHP Manual — FastCGI Process Manager: https://www.php.net/manual/en/install.fpm.configuration.php"

kb phpfpm.opcache "Application Runtime" \
  "OPcache appears disabled or unavailable. Without opcode caching, PHP recompiles scripts on every request, adding significant CPU overhead." \
  "PHP Manual — OPcache: https://www.php.net/manual/en/book.opcache.php"

kb python.generic "Application Runtime" \
  "Review worker process count/model (sync vs. gevent/uvloop) against CPU core count and request concurrency; a single sync worker blocks on I/O-bound requests." \
  "Gunicorn Docs — Design: https://docs.gunicorn.org/en/stable/design.html"

kb java.heap "Application Runtime" \
  "Review JVM heap sizing and GC pause behavior; undersized heaps cause frequent full GCs and latency spikes." \
  "Oracle — Java Garbage Collection Tuning Guide: https://docs.oracle.com/en/java/javase/17/gctuning/"

kb dotnet.generic "Application Runtime" \
  "Review server GC vs workstation GC configuration and thread-pool sizing for .NET workloads under load." \
  "Microsoft Learn — .NET Garbage Collection: https://learn.microsoft.com/dotnet/standard/garbage-collection/"

# ── Containers / Orchestration ───────────────────────────────────────────
kb docker.logdriver "Containers" \
  "The default json-file log driver has no size limit unless configured, and can fill the root filesystem. Set max-size/max-file (or a centralized log driver) in daemon.json." \
  "Docker Docs — Configure logging drivers: https://docs.docker.com/config/containers/logging/configure/"

kb docker.diskusage "Containers" \
  "Reclaimable space (dangling images/build cache/stopped containers) is high. Review 'docker system df' and establish a pruning policy appropriate to the environment." \
  "Docker Docs — Prune unused Docker objects: https://docs.docker.com/config/pruning/"

kb podman.generic "Containers" \
  "Review rootless vs rootful container placement and storage driver choice against workload isolation requirements." \
  "Podman Docs: https://docs.podman.io/en/latest/"

kb kubernetes.nodepressure "Containers/Orchestration" \
  "Node reports memory/disk/PID pressure conditions. Pods may be evicted; review resource requests/limits and node capacity." \
  "Kubernetes Docs — Node-pressure Eviction: https://kubernetes.io/docs/concepts/scheduling-eviction/node-pressure-eviction/"

kb kubernetes.generic "Containers/Orchestration" \
  "Review pod restart counts, resource requests/limits vs actual usage, and cluster event stream for scheduling problems." \
  "Kubernetes Docs — Resource Management for Pods and Containers: https://kubernetes.io/docs/concepts/configuration/manage-resources-containers/"
