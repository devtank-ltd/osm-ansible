  - job_name: "{{ inventory_hostname }}"
    static_configs:
      - targets: ["{{ wg_ip }}:9100"]

  - job_name: "{{ inventory_hostname }}-container"
    metrics_path: "/api/v1/allmetrics?format=prometheus&help=yes"
    honor_labels: true
    static_configs:
      - targets: ["{{ wg_ip }}:19999"]
