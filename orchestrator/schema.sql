CREATE DATABASE osm_orchestrator;
USE osm_orchestrator;

CREATE TABLE osm_hosts (
    id INT PRIMARY KEY AUTO_INCREMENT,
    name    TEXT NOT NULL,
    ip_addr TEXT NOT NULL,
    capacity    INTEGER NOT NULL,
    active_since BIGINT NOT NULL,
    active_before BIGINT
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

CREATE TABLE osm_wireguard (
    id           INT  PRIMARY KEY AUTO_INCREMENT,
    osm_hosts_id INT  NULL,
    public_key   TEXT NOT NULL,
    private_key  TEXT NOT NULL,
    ip_addr      TEXT NOT NULL,
    FOREIGN KEY(osm_hosts_id) REFERENCES osm_hosts (id)
);

CREATE TABLE osm_secrets (
    id              INT PRIMARY KEY AUTO_INCREMENT,
    osm_customer_id INTEGER NOT NULL,
    secrets         TEXT    NOT NULL,
    FOREIGN KEY(osm_customer_id) REFERENCES osm_customers (id)
);

ALTER TABLE osm_wireguard AUTO_INCREMENT = 2;

GRANT ALL PRIVILEGES ON osm_orchestrator.* TO 'osm_orchestrator'@'localhost' IDENTIFIED BY 'change_this_password';
GRANT ALL PRIVILEGES ON pdns.records TO 'osm_orchestrator'@'localhost';
