-- grants_lpar2rrd.sql
--
-- Views que o LPAR2RRD consulta e que estao devolvendo ORA-00942 ao usuario de
-- monitoracao. Cada uma alimenta um datasource especifico; sem o GRANT o
-- coletor grava "U" e o grafico mostra -nan.
--
--   V$LOG                 -> Capacity / log_capacity   (aba Online Redo Logs)
--   V$RECOVERY_FILE_DEST  -> Cpct / recoverysize, recoveryused
--                                                      (aba Recovery File Destination)
--   V$CONTROLFILE         -> Cpct / controlfiles
--
-- O GRANT e sobre V_$<nome>, com underscore: V$<nome> e sinonimo publico e nao
-- aceita GRANT direto.
--
-- Rode como SYS / AS SYSDBA em cada banco monitorado, trocando &&usuario.
-- Em Multitenant, rode no CDB$ROOT com CONTAINER=ALL se o usuario for comum.

DEFINE usuario = LPAR2RRD

prompt == antes ==
SELECT table_name, privilege
  FROM dba_tab_privs
 WHERE grantee = upper('&&usuario')
   AND table_name IN ('V_$LOG','V_$RECOVERY_FILE_DEST','V_$CONTROLFILE')
 ORDER BY table_name;

GRANT SELECT ON V_$LOG                TO &&usuario;
GRANT SELECT ON V_$RECOVERY_FILE_DEST TO &&usuario;
GRANT SELECT ON V_$CONTROLFILE        TO &&usuario;

prompt == depois ==
SELECT table_name, privilege
  FROM dba_tab_privs
 WHERE grantee = upper('&&usuario')
   AND table_name IN ('V_$LOG','V_$RECOVERY_FILE_DEST','V_$CONTROLFILE')
 ORDER BY table_name;

-- Conferencia: as tres consultas abaixo sao as mesmas de oracledb-sql/*_L.sql.
-- Rode-as COMO O USUARIO DE MONITORACAO. Se as tres devolverem numero, os
-- graficos voltam na proxima coleta.
--
--   SELECT SUM(BYTES)/1073741824 FROM V$LOG;
--   SELECT NVL(SUM(space_limit),0)/1024/1024/1024,
--          NVL(SUM(space_used),0)/1024/1024/1024 FROM V$RECOVERY_FILE_DEST;
--   SELECT SUM(BLOCK_SIZE*FILE_SIZE_BLKS)/1024/1024/1024 FROM V$CONTROLFILE;
