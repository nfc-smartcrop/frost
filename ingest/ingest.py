#!/usr/bin/env python3
"""
SmartCrop Frost — ingest + alert service (v2: subscriber-owned thresholds).

- Subscribes to ChirpStack's MQTT integration (application/+/device/+/event/up)
- Stores every temperature uplink in Postgres
- For each reading, evaluates every subscription covering that sensor
  (by ranch or by sensor) against that subscriber's own low/clear thresholds,
  with independent hysteresis state per (subscription, sensor)
- Offline watchdog per subscription (each person picks their own timeout)
- Delivers by SMS (Twilio), email (SMTP), or signed webhook
- Honours per-subscriber quiet hours

Everything is driven by companies / ranches / sensors / subscribers /
subscriptions tables; adding a sensor, a person, or a rule is a row, not code.
"""

import hashlib
import hmac
import json
import logging
import os
import re
import smtplib
import threading
import time
import urllib.request
from datetime import datetime, timezone
from email.message import EmailMessage

import paho.mqtt.client as mqtt
import psycopg
from psycopg.rows import dict_row

# ---------------------------------------------------------------- config ----

MQTT_HOST = os.getenv("MQTT_HOST", "mosquitto")
MQTT_PORT = int(os.getenv("MQTT_PORT", "1883"))
PG_DSN = os.getenv("PG_DSN", "postgresql://frost:frost@postgres:5432/frost")

OFFLINE_CHECK_SECONDS = int(os.getenv("OFFLINE_CHECK_SECONDS", "60"))
BRAND = os.getenv("BRAND", "SmartCrop Frost")

# Twilio (optional)
TWILIO_SID = os.getenv("TWILIO_ACCOUNT_SID")
TWILIO_TOKEN = os.getenv("TWILIO_AUTH_TOKEN")
TWILIO_FROM = os.getenv("TWILIO_FROM")

# SMTP (optional): authenticated provider or IP-allowed internal relay
SMTP_HOST = os.getenv("SMTP_HOST")
SMTP_PORT = int(os.getenv("SMTP_PORT", "25"))
SMTP_USER = os.getenv("SMTP_USER") or None
SMTP_PASS = os.getenv("SMTP_PASS") or None
SMTP_STARTTLS = os.getenv("SMTP_STARTTLS", "auto").lower()   # auto | yes | no
SMTP_FROM = os.getenv("SMTP_FROM", SMTP_USER or "frost@localhost")

# Webhook (optional)
WEBHOOK_SECRET = os.getenv("WEBHOOK_SECRET", "")
WEBHOOK_TIMEOUT = int(os.getenv("WEBHOOK_TIMEOUT", "10"))

# Unknown sensors: register under this company so first uplinks aren't lost.
AUTO_REGISTER = os.getenv("AUTO_REGISTER", "true").lower() == "true"
DEFAULT_COMPANY = os.getenv("DEFAULT_COMPANY", "Northern Fruit")

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("smartcrop-frost")


# --------------------------------------------------------------- helpers ----

def c_to_f(c):
    return c * 9.0 / 5.0 + 32.0


TEMP_KEYS = re.compile(r"^(temp|tempc|temp_c|temperature)", re.I)
BAT_KEYS = re.compile(r"^(bat|batv|bat_v|battery|batteryvoltage)", re.I)


def extract_temp_c(obj):
    """Dragino field names vary (TempC1, TempC_DS, TempC_SHT...). Take the first
    numeric Celsius-looking field; skip 'NULL' / ±327.67 disconnected sentinels."""
    if not isinstance(obj, dict):
        return None
    for key, val in obj.items():
        if TEMP_KEYS.match(key):
            try:
                v = float(val)
            except (TypeError, ValueError):
                continue
            if abs(v) > 300:
                continue
            return v
    return None


def extract_battery_v(obj):
    if not isinstance(obj, dict):
        return None
    for key, val in obj.items():
        if BAT_KEYS.match(key):
            try:
                v = float(val)
                return v / 1000.0 if v > 100 else v
            except (TypeError, ValueError):
                continue
    return None


def best_rx(rx_info):
    if not rx_info:
        return None, None, None
    best = max(rx_info, key=lambda r: r.get("rssi", -999))
    return best.get("gatewayId"), best.get("rssi"), best.get("snr")


def in_quiet_hours(sub, now=None):
    """quiet_start/quiet_end are time-of-day; window may cross midnight."""
    qs, qe = sub.get("quiet_start"), sub.get("quiet_end")
    if not qs or not qe:
        return False
    t = (now or datetime.now()).time()
    if qs <= qe:
        return qs <= t < qe
    return t >= qs or t < qe


# --------------------------------------------------------- delivery ---------

def send_sms(to, body):
    if not (TWILIO_SID and TWILIO_TOKEN and TWILIO_FROM):
        log.warning("SMS not configured; would send to %s: %s", to, body)
        return False
    try:
        from twilio.rest import Client
        Client(TWILIO_SID, TWILIO_TOKEN).messages.create(to=to, from_=TWILIO_FROM, body=body)
        return True
    except Exception as e:  # noqa: BLE001
        log.error("SMS to %s failed: %s", to, e)
        return False


def send_email(to, subject, body):
    if not SMTP_HOST:
        log.warning("Email not configured; would send to %s: %s", to, subject)
        return False
    try:
        msg = EmailMessage()
        msg["From"] = SMTP_FROM
        msg["To"] = to
        msg["Subject"] = subject
        msg.set_content(body)
        with smtplib.SMTP(SMTP_HOST, SMTP_PORT, timeout=20) as s:
            s.ehlo()
            if SMTP_STARTTLS == "yes" or (SMTP_STARTTLS == "auto" and s.has_extn("starttls")):
                s.starttls()
                s.ehlo()
            if SMTP_USER and SMTP_PASS:
                s.login(SMTP_USER, SMTP_PASS)
            s.send_message(msg)
        return True
    except Exception as e:  # noqa: BLE001
        log.error("Email to %s failed: %s", to, e)
        return False


def send_webhook(url, event):
    body = json.dumps(event).encode("utf-8")
    headers = {"Content-Type": "application/json", "User-Agent": "smartcrop-frost/2.0"}
    if WEBHOOK_SECRET:
        sig = hmac.new(WEBHOOK_SECRET.encode(), body, hashlib.sha256).hexdigest()
        headers["X-Frost-Signature"] = f"sha256={sig}"
    try:
        req = urllib.request.Request(url, data=body, headers=headers, method="POST")
        with urllib.request.urlopen(req, timeout=WEBHOOK_TIMEOUT) as resp:
            return 200 <= resp.status < 300
    except Exception as e:  # noqa: BLE001
        log.error("Webhook to %s failed: %s", url, e)
        return False


def deliver(conn, sub, sensor, kind, temp_c, message):
    """Send one alert to one subscriber and log it. Returns delivered bool."""
    if in_quiet_hours(sub):
        log.info("quiet hours: suppressed %s for %s (%s)", kind, sub["name"], sensor["name"])
        return None  # not delivered, not an error; caller leaves state unchanged

    subject = f"[{BRAND}] {sensor['name']}: {kind.replace('_', ' ')}"
    event = {
        "type": kind,
        "dev_eui": sensor["dev_eui"],
        "sensor": sensor["name"],
        "company": sensor.get("company_name"),
        "ranch": sensor.get("ranch_name"),
        "placement": sensor.get("placement"),
        "temp_c": float(temp_c) if temp_c is not None else None,
        "temp_f": round(c_to_f(float(temp_c)), 1) if temp_c is not None else None,
        "subscription_id": sub["subscription_id"],
        "subscriber": sub["name"],
        "message": message,
        "at": datetime.now(timezone.utc).isoformat(),
    }
    ch = sub["channel"]
    if ch == "sms":
        ok = send_sms(sub["address"], message)
    elif ch == "email":
        ok = send_email(sub["address"], subject, message)
    elif ch == "webhook":
        ok = send_webhook(sub["address"], event)
    else:
        ok = False

    with conn.cursor() as cur:
        cur.execute(
            """insert into alerts (subscription_id, subscriber_id, dev_eui, kind, temp_c, message, delivered)
               values (%s, %s, %s, %s, %s, %s, %s)""",
            (sub["subscription_id"], sub["subscriber_id"], sensor["dev_eui"], kind, temp_c, message, ok),
        )
    conn.commit()
    log.info("ALERT %s -> %s (%s %s) %s", kind, sub["name"], ch, sub["address"], "ok" if ok else "FAILED")
    return ok


# ------------------------------------------------------------- queries ------

SENSOR_SQL = """
select s.dev_eui, s.name, s.placement, s.enabled, s.company_id, s.ranch_id,
       c.name as company_name, r.name as ranch_name
  from sensors s
  join companies c on c.id = s.company_id
  left join ranches r on r.id = s.ranch_id
 where s.dev_eui = %s
"""

SUBS_FOR_SENSOR_SQL = """
select x.id as subscription_id, x.low_temp_c, x.clear_temp_c, x.notify_offline, x.offline_minutes,
       sub.id as subscriber_id, sub.name, sub.channel, sub.address, sub.quiet_start, sub.quiet_end,
       coalesce(a.low_active, false) as low_active, coalesce(a.offline_active, false) as offline_active
  from subscriptions x
  join subscribers sub on sub.id = x.subscriber_id and sub.enabled
  left join alert_state a on a.subscription_id = x.id and a.dev_eui = %(dev_eui)s
 where x.enabled
   and sub.company_id = %(company_id)s
   and (x.dev_eui = %(dev_eui)s or (x.ranch_id is not null and x.ranch_id = %(ranch_id)s))
"""


def set_state(conn, subscription_id, dev_eui, low_active=None, offline_active=None):
    with conn.cursor() as cur:
        cur.execute(
            """insert into alert_state (subscription_id, dev_eui, low_active, offline_active, updated_at)
               values (%s, %s, coalesce(%s, false), coalesce(%s, false), now())
               on conflict (subscription_id, dev_eui) do update
                  set low_active     = coalesce(%s, alert_state.low_active),
                      offline_active = coalesce(%s, alert_state.offline_active),
                      updated_at     = now()""",
            (subscription_id, dev_eui, low_active, offline_active, low_active, offline_active),
        )
    conn.commit()


def where_text(sensor):
    return " / ".join(x for x in [sensor.get("ranch_name"), sensor.get("placement")] if x)


# ----------------------------------------------------------------- rules ----

def evaluate_reading(conn, sensor, temp_c, ts):
    with conn.cursor(row_factory=dict_row) as cur:
        cur.execute(SUBS_FOR_SENSOR_SQL,
                    {"dev_eui": sensor["dev_eui"], "company_id": sensor["company_id"], "ranch_id": sensor["ranch_id"]})
        subs = cur.fetchall()

    for sub in subs:
        low, clear = float(sub["low_temp_c"]), float(sub["clear_temp_c"])
        when = ts.astimezone().strftime("%H:%M")

        # Sensor came back after this subscription flagged it offline
        if sub["offline_active"]:
            if deliver(conn, sub, sensor, "back_online", temp_c,
                       f"Back online: {sensor['name']} ({where_text(sensor)}) — {temp_c:.1f}°C / {c_to_f(temp_c):.1f}°F") is not None:
                set_state(conn, sub["subscription_id"], sensor["dev_eui"], offline_active=False)

        if not sub["low_active"] and temp_c <= low:
            msg = (f"FROST ALERT {sensor['name']} ({where_text(sensor)}): "
                   f"{temp_c:.1f}°C / {c_to_f(temp_c):.1f}°F at {when} "
                   f"(your threshold {low:.1f}°C / {c_to_f(low):.1f}°F)")
            if deliver(conn, sub, sensor, "low_temp", temp_c, msg) is not None:
                set_state(conn, sub["subscription_id"], sensor["dev_eui"], low_active=True)
        elif sub["low_active"] and temp_c >= clear:
            msg = (f"Cleared {sensor['name']} ({where_text(sensor)}): "
                   f"{temp_c:.1f}°C / {c_to_f(temp_c):.1f}°F at {when}")
            if deliver(conn, sub, sensor, "low_temp_clear", temp_c, msg) is not None:
                set_state(conn, sub["subscription_id"], sensor["dev_eui"], low_active=False)


def offline_watchdog(dsn):
    """Every OFFLINE_CHECK_SECONDS: for each enabled sensor with a last_seen,
    find subscriptions covering it that want offline alerts and whose timeout
    has elapsed, and notify those not already notified."""
    while True:
        try:
            with psycopg.connect(dsn, row_factory=dict_row) as conn:
                with conn.cursor() as cur:
                    cur.execute("""
                        select s.dev_eui, s.name, s.placement, s.company_id, s.ranch_id,
                               c.name as company_name, r.name as ranch_name, st.last_seen
                          from sensors s
                          join companies c on c.id = s.company_id
                          left join ranches r on r.id = s.ranch_id
                          join sensor_status st on st.dev_eui = s.dev_eui
                         where s.enabled and st.last_seen is not null
                    """)
                    sensors = cur.fetchall()

                now = datetime.now(timezone.utc)
                for sensor in sensors:
                    silent_min = (now - sensor["last_seen"]).total_seconds() / 60.0
                    with conn.cursor() as cur:
                        cur.execute(SUBS_FOR_SENSOR_SQL,
                                    {"dev_eui": sensor["dev_eui"], "company_id": sensor["company_id"], "ranch_id": sensor["ranch_id"]})
                        subs = cur.fetchall()
                    for sub in subs:
                        if not sub["notify_offline"] or sub["offline_active"]:
                            continue
                        if silent_min > sub["offline_minutes"]:
                            msg = (f"OFFLINE {sensor['name']} ({where_text(sensor)}): no data for "
                                   f"{int(silent_min)} min (last seen {sensor['last_seen'].astimezone().strftime('%H:%M')})")
                            if deliver(conn, sub, sensor, "offline", None, msg) is not None:
                                set_state(conn, sub["subscription_id"], sensor["dev_eui"], offline_active=True)
        except Exception as e:  # noqa: BLE001
            log.error("offline watchdog error: %s", e)
        time.sleep(OFFLINE_CHECK_SECONDS)


# ------------------------------------------------------------------ MQTT ----

def get_or_register_sensor(conn, dev_eui, name, tenant_id):
    with conn.cursor(row_factory=dict_row) as cur:
        cur.execute(SENSOR_SQL, (dev_eui,))
        sensor = cur.fetchone()
        if sensor:
            return sensor
        if not AUTO_REGISTER:
            return None
        # Company by ChirpStack tenant id if we know it, else the default company
        cur.execute("select id from companies where tenant_id::text = %s", (tenant_id,))
        row = cur.fetchone()
        if not row:
            cur.execute("insert into companies (name) values (%s) on conflict (name) do update set name = excluded.name returning id",
                        (DEFAULT_COMPANY,))
            row = cur.fetchone()
        cur.execute("insert into sensors (dev_eui, company_id, name) values (%s, %s, %s) on conflict do nothing",
                    (dev_eui, row["id"], name))
        conn.commit()
        log.info("auto-registered sensor %s as '%s' (unassigned ranch)", dev_eui, name)
        cur.execute(SENSOR_SQL, (dev_eui,))
        return cur.fetchone()


def handle_uplink(conn, payload):
    dev = payload.get("deviceInfo", {})
    dev_eui = (dev.get("devEui") or "").lower()
    if not dev_eui:
        return
    name = dev.get("deviceName") or dev_eui
    tenant_id = dev.get("tenantId")

    obj = payload.get("object") or {}
    temp_c = extract_temp_c(obj)
    bat_v = extract_battery_v(obj)
    gw_id, rssi, snr = best_rx(payload.get("rxInfo", []))
    f_cnt = payload.get("fCnt")
    ts_raw = payload.get("time")
    try:
        ts = datetime.fromisoformat(ts_raw.replace("Z", "+00:00")) if ts_raw else datetime.now(timezone.utc)
    except Exception:  # noqa: BLE001
        ts = datetime.now(timezone.utc)

    sensor = get_or_register_sensor(conn, dev_eui, name, tenant_id)
    if sensor is None:
        log.warning("uplink from unregistered sensor %s; ignoring", dev_eui)
        return

    with conn.cursor() as cur:
        cur.execute(
            """insert into readings (dev_eui, ts, temp_c, battery_v, rssi, snr, gateway_id, f_cnt, raw)
               values (%s, %s, %s, %s, %s, %s, %s, %s, %s)""",
            (dev_eui, ts, temp_c, bat_v, rssi, snr, gw_id, f_cnt, json.dumps(obj)),
        )
        cur.execute(
            """insert into sensor_status (dev_eui, last_seen, last_temp_c, last_battery_v, updated_at)
               values (%s, %s, %s, %s, now())
               on conflict (dev_eui) do update
                  set last_seen = excluded.last_seen,
                      last_temp_c = coalesce(excluded.last_temp_c, sensor_status.last_temp_c),
                      last_battery_v = coalesce(excluded.last_battery_v, sensor_status.last_battery_v),
                      updated_at = now()""",
            (dev_eui, ts, temp_c, bat_v),
        )
    conn.commit()

    log.info("%s [%s] temp=%s°C bat=%sV rssi=%s snr=%s gw=%s",
             sensor["name"], sensor.get("ranch_name") or "unassigned", temp_c, bat_v, rssi, snr, gw_id)

    if temp_c is not None and sensor["enabled"]:
        evaluate_reading(conn, sensor, temp_c, ts)


def main():
    while True:
        try:
            conn = psycopg.connect(PG_DSN)
            break
        except Exception as e:  # noqa: BLE001
            log.info("waiting for postgres: %s", e)
            time.sleep(3)

    threading.Thread(target=offline_watchdog, args=(PG_DSN,), daemon=True).start()

    client = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2, client_id="smartcrop-frost-ingest")

    def on_connect(c, userdata, flags, reason_code, properties):
        log.info("MQTT connected (%s); subscribing", reason_code)
        c.subscribe("application/+/device/+/event/up", qos=0)

    def on_message(c, userdata, msg):
        try:
            handle_uplink(conn, json.loads(msg.payload.decode("utf-8")))
        except Exception as e:  # noqa: BLE001
            log.exception("failed to handle uplink: %s", e)
            try:
                conn.rollback()
            except Exception:  # noqa: BLE001
                pass

    client.on_connect = on_connect
    client.on_message = on_message
    client.reconnect_delay_set(min_delay=1, max_delay=30)
    while True:
        try:
            client.connect(MQTT_HOST, MQTT_PORT, keepalive=60)
            break
        except Exception as e:  # noqa: BLE001
            log.info("waiting for mqtt: %s", e)
            time.sleep(3)

    log.info("%s ingest v2 running", BRAND)
    client.loop_forever()


if __name__ == "__main__":
    main()
