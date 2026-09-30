# Prints the Odoo databases whose base module is on this image's series. Queries postgres directly
# because list_dbs() collapses to db_name when the conf sets one, and the series check keeps
# leftover pre-migration copies from being updated with newer code.
from odoo.release import series
from odoo.sql_db import db_connect
from odoo.tools import config

config.parse_config(['-c', '/etc/odoo/odoo.conf'])

with db_connect('postgres').cursor() as cr:
    cr.execute("SELECT datname FROM pg_database WHERE datallowconn AND NOT datistemplate AND datname <> 'postgres' ORDER BY 1")
    names = [row[0] for row in cr.fetchall()]

for name in names:
    try:
        with db_connect(name).cursor() as cr:
            cr.execute("SELECT latest_version FROM ir_module_module WHERE name = 'base'")
            row = cr.fetchone()
    except Exception:
        continue
    if row and row[0] and row[0].startswith(f'{series}.'):
        print(name)
