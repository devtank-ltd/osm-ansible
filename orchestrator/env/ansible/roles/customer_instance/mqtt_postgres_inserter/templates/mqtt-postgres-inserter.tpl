debug: 0
postgres:
  host: 127.0.0.1
  db: {{ timescaledb_db }}
  port: 5432
  user: {{ timescaledb_owner }}
  password: {{ timescaledb_passwords['devtank'] }}
mqtt:
  address: 127.0.0.1
  password: {{ mosquitto_passwd }}
  port: 1883
  topic: osm/#
  username: {{ customer_name }}
prometheus:
  orch_wg_ip: {{ main_wg_ip }}
  push_gateway_port: 9091
