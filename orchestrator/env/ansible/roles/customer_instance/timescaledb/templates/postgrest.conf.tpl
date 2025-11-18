db-uri = "postgres://customer:{{ timescaledb_passwords['customer'] }}@localhost/{{ timescaledb_db }}"
db-schema = "public"
server-port = 3001
jwt-secret = "{{ jwt_secret }}"
max-db-rows = 100000
