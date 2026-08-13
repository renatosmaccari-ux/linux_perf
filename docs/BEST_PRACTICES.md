# Metodologia e Referências

Todo achado (*finding*) gerado por este projeto é derivado de um limite ou
condição documentada por um fornecedor/projeto upstream — não de um valor
arbitrário do autor. A tabela de recomendações vive em [`lib/kb.sh`](../lib/kb.sh);
este documento é a versão legível para revisão fora da execução da ferramenta.

## Sistema Operacional / Kernel

| Área | Prática de referência | Fonte |
|---|---|---|
| CPU / Load | Investigar saturação sustentada da fila de execução antes de escalar | Red Hat — Monitoring and Managing System Status and Performance |
| Memória | Distinguir cache de pressão real via `MemAvailable` | Red Hat — Analyzing System Performance |
| Swap | `vm.swappiness` baixo (1–10) em hosts de banco de dados | Kernel.org — admin-guide/sysctl/vm |
| Disco | Alertar em ~85% de uso; monitorar inodes separadamente | Red Hat — Managing Storage Devices / Managing File Systems |
| Rede | `TIME_WAIT` excessivo indica esgotamento de portas efêmeras | Kernel.org — ip-sysctl.txt |
| THP | Desabilitar/definir `madvise` para cargas de banco de dados | Red Hat Solution 46111; MongoDB Production Notes |
| Patching | Priorizar CVEs de kernel e serviços expostos à rede | Documentação de `dnf`/`zypper`/`apt` de cada distro |
| MAC (SELinux/AppArmor) | Enforcing por padrão como camada de defesa em profundidade | Red Hat SELinux Guide; Ubuntu AppArmor docs |

## Bancos de Dados

| Produto | Métrica-chave | Fonte |
|---|---|---|
| MySQL/MariaDB | Buffer pool hit rate ≥ 99%; `innodb_buffer_pool_size` 60–75% da RAM | MySQL 8.0 Reference Manual — InnoDB Buffer Pool |
| PostgreSQL | Cache hit ratio ≥ 99%; autovacuum acompanhando dead tuples | PostgreSQL Docs — Routine Vacuuming, Runtime Config |
| Redis | Hit rate ≥ 80%; `maxmemory-policy` explícita | Redis Docs — Memory Optimization, Eviction Policies |
| MongoDB | Conexões e cache do WiredTiger dentro da capacidade planejada | MongoDB — Production Notes |
| Elasticsearch/OpenSearch | Heap JVM ≈ 50% da RAM (máx. ~32 GB); cluster health verde | Elastic Docs — Important Settings, Cluster Health API |

## Web / Proxy / Cache

| Produto | Prática | Fonte |
|---|---|---|
| NGINX | Expor `stub_status`/API para métricas ao vivo | NGINX Docs — ngx_http_stub_status_module |
| Apache HTTPD | Expor `mod_status` | Apache HTTP Server Docs |
| HAProxy | Socket de administração para coleta sem expor a stats page publicamente | HAProxy Management Guide |
| Varnish | Hit ratio e VCL/Vary sob controle | Varnish Docs — Increasing your Hitrate |

## Mensageria

| Produto | Prática | Fonte |
|---|---|---|
| RabbitMQ | Filas sem consumidor e em crescimento indicam gargalo | RabbitMQ — Production Checklist |
| Kafka | Zero partições sub-replicadas; lag de consumidor monitorado | Apache Kafka — Operations |

## Runtimes de Aplicação

| Runtime | Prática | Fonte |
|---|---|---|
| Node.js | Clusterizar para workloads CPU-bound (processo único = 1 core) | Node.js Docs — Diagnostics |
| PHP-FPM | OPcache habilitado; pool status exposto | PHP Manual — OPcache, FPM Configuration |
| Python (WSGI/ASGI) | Nº de workers alinhado a cores/concorrência | Gunicorn Docs — Design |
| Java/JVM | Heap dimensionado para evitar full GC frequente | Oracle — Java Garbage Collection Tuning Guide |
| .NET | Server GC e thread-pool avaliados sob carga | Microsoft Learn — .NET Garbage Collection |

## Containers / Orquestração

| Produto | Prática | Fonte |
|---|---|---|
| Docker | Limitar `json-file` (`max-size`/`max-file`) para não estourar disco | Docker Docs — Configure Logging Drivers |
| Podman | Avaliar rootless vs. rootful conforme isolamento exigido | Podman Docs |
| Kubernetes | Sem condições de `MemoryPressure`/`DiskPressure`/`PIDPressure` nos nós | Kubernetes Docs — Node-pressure Eviction |

---

Esta lista é indicativa; a versão autoritativa (usada para gerar o relatório) é
sempre `lib/kb.sh`, que é onde novas recomendações devem ser adicionadas ou
atualizadas.
