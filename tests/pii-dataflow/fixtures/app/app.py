"""Fixture web app with personal data flows for the privado scan: a sign-up
form (source), a database write and a log line (sinks), a third-party CRM
call (third party)."""
import logging
import sqlite3

import requests
from flask import Flask, request

app = Flask(__name__)
log = logging.getLogger("signup")
CRM_URL = "https://api.example-crm.com/v1/contacts"


@app.post("/signup")
def signup():
    email = request.form["email"]
    first_name = request.form["first_name"]
    phone = request.form.get("phone", "")
    log.info("signup for %s", email)
    with sqlite3.connect("users.db") as db:
        db.execute("insert into users (email, first_name, phone) values (?, ?, ?)", (email, first_name, phone))
    requests.post(CRM_URL, json={"email": email, "firstName": first_name, "phone": phone}, timeout=5)
    return {"ok": True}


@app.get("/profile")
def profile():
    with sqlite3.connect("users.db") as db:
        row = db.execute("select email, first_name from users where id = ?", (request.args["id"],)).fetchone()
    return {"email": row[0], "first_name": row[1]}
