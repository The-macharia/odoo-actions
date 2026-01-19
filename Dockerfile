FROM odoo:18.0
USER root

COPY requirements.txt mnt/extra-addons
RUN pip3 install --break-system-packages -r /mnt/extra-addons/requirements.txt --no-cache-dir

RUN mkdir -p /var/log/odoo

RUN chown -R odoo:odoo /var/log/odoo

RUN chmod 777 /var/log/odoo

USER odoo
