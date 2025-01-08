#!/usr/bin/env python

import asyncio
import logging
import os
import sys
import uvicorn
import yaml

from fastapi import FastAPI
from pathlib import Path
from typing import Union
from pydantic import BaseModel

from orchestrator_cli import (
    cli_osm_orchestrator_t,
    osm_host_t,
    osm_orchestrator_t,
    do_db_single_query,
    SQL_GET_CUSTOMER_PORT,
)

LOG = logging.getLogger("fastapi")
app = FastAPI()

class Customer(BaseModel):
    name: str


@app.get("/")
def read_root():
    return {"message": "Devtank"}

@app.post("/add_host")
async def add_host(name: str, ipaddr: str, capacity: int):
    return osm_orch.add_osm_host(name, ipaddr, capacity)

@app.post("/del_host")
def del_host(name: str):
    return osm_orch.del_osm_host(name)

@app.post("/find_host")
def find_host(customer_name: str):
    osm_host = osm_orch.find_osm_host_of(customer_name)
    return osm_host.name

@app.post("/test_host")
def test_host(name: str):

    osm_host = osm_orch.find_osm_host(name)
    if osm_host:
        return True if osm_host.get_ssh() else False
    return False

@app.post("/del_customer")
def del_customer(name: str):
    return osm_orch.del_osm_customer(name)

@app.post("/mv_customer")
async def mv_customer(name: str, host: str):
    return osm_orch.move_osm_customer(name, host)

@app.post("/upd_customer_obase")
async def upd_customer_obase(name: str):
    return osm_orch.upd_osm_customer(name)

@app.get("/list_host_customers")
def list_host_customers(name: str):
    data: dict[str, Union[str, list]] = {}
    osm_host = osm_orch.find_osm_host(name)
    if not osm_host:
        LOG.error("Unabme to find OSM host '%s'", name)
        return data
    else:
        data = {
            "capacity": osm_host.capacity,
            "customers": [
                {
                    'name': customer,
                    'mqtt_port': do_db_single_query(
                        osm_orch.db,
                        SQL_GET_CUSTOMER_PORT,
                        (customer,)
                    )[0]
                } for customer in osm_host.customers
            ]
        }

    return data

@app.get("/list_customers")
def list_customers():
    customers = {}
    osm_hosts = osm_orch.list_hosts()

    for host in osm_hosts:
        customers[host.name] = host.customers

    return customers

@app.get("/list_hosts")
def list_hosts():
    return [host.name for host in osm_orch.list_hosts()]

@app.post("/get_customer_passwords")
def get_customer_passwords(name: str):
    return osm_orch.get_customer_passwords(name)

@app.post("/get_wg_info")
def get_wg_info(name: str):
    return osm_orch.get_wg_info(name)

@app.post("/add_customer")
async def add_customer(customer: Customer):
    return osm_orch.add_osm_customer(customer.name)


if __name__ == "__main__":
    config = Path("config.yaml")
    if config.exists():
        config = config.resolve(strict=True)
    else:
        LOG.error("No config.yaml found.")
        sys.exit(os.EX_UNAVAILABLE)

    try:
        config = yaml.safe_load(open("config.yaml"))
    except yaml.YAMLError as err:
        LOG.error(err)
        if hasattr(err, "problem_mark"):
            mark = err.problem_mark
            LOG.error("Error position: %s:%s", mark.line+1, mark.column+1)

    osm_orch = osm_orchestrator_t(config)
    cli_obj = cli_osm_orchestrator_t(osm_orch)

    uvicorn.run(app, host="0.0.0.0", port=8000)
