FROM python:3.11-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PORT=8080 \
    LOG_PATH=/var/log/app/dice.log

ARG APP_UID=10001
ARG APP_GID=10001
RUN groupadd -g ${APP_GID} app && useradd -u ${APP_UID} -g ${APP_GID} -s /usr/sbin/nologin -m app

WORKDIR /app

COPY app/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app/app.py /app/

RUN mkdir -p /var/log/app && chown -R ${APP_UID}:${APP_GID} /var/log/app /app

USER ${APP_UID}:${APP_GID}

EXPOSE 8080
CMD ["gunicorn", "-b", "0.0.0.0:8080", "--workers", "2", "--threads", "4", "app:app"]