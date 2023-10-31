CREATE TABLE osm_hosts (
    id INT PRIMARY KEY AUTO_INCREMENT,
    name    TEXT NOT NULL,
    ip_addr TEXT NOT NULL,
    username    TEXT NOT NULL,
    capacity    INTEGER NOT NULL
);

CREATE TABLE osm_customers (
    id INT PRIMARY KEY AUTO_INCREMENT,
    osm_hosts_id    INTEGER NOT NULL,
    name    TEXT NOT NULL,
    host_mqtt_port  INTEGER NOT NULL,
    active_since BIGINT NOT NULL,
    active_before BIGINT,
    FOREIGN KEY(osm_hosts_id) REFERENCES osm_hosts (id)
);
