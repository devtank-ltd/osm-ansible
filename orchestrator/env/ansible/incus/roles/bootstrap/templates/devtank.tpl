# Managed by Ansible, do not modify
Types: deb deb-src
URIs: {{ devtank.apt_repo }}
Suites: testing
Components: main
Signed-By: /etc/apt/keyrings/{{ devtank.gpg_key }}
