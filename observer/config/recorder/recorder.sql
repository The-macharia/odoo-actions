-- One JSON line per session every 30s, kept in Loki. Idle pooled connections are only listed once
-- the server is past 80% of max_connections, which is exactly when they matter.
SELECT json_build_object(
           'holder', application_name,
           'pid', pid,
           'db', datname,
           'user', usename,
           'client', host(client_addr),
           'state', state,
           'wait', wait_event_type || ':' || wait_event,
           'blocked_by', pg_blocking_pids(pid),
           'xact_s', round(extract(epoch FROM now() - xact_start)),
           'query_s', round(extract(epoch FROM now() - query_start)),
           'conn_s', round(extract(epoch FROM now() - backend_start)),
           'query', left(query, 2000))
FROM pg_stat_activity
WHERE backend_type = 'client backend'
  AND pid <> pg_backend_pid()
  AND (state <> 'idle'
       OR (SELECT count(*) FROM pg_stat_activity) > 0.8 * current_setting('max_connections')::int)
\watch 30
