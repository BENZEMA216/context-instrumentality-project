FROM python:3.12-slim
WORKDIR /build
COPY pyproject.toml .
COPY schema/context-event.schema.json schema/context-event.schema.json
COPY channels/audio/record-for-agent/AgentBridge/library.py channels/audio/record-for-agent/AgentBridge/library.py
COPY hub hub
RUN pip install --no-cache-dir . && useradd --system --uid 10001 --create-home hub \
    && mkdir -p /var/lib/context-hub && chown hub /var/lib/context-hub
USER hub
ENV HUB_DATA_DIR=/var/lib/context-hub PYTHONUNBUFFERED=1
WORKDIR /home/hub
VOLUME ["/var/lib/context-hub"]
EXPOSE 8741
ENTRYPOINT ["context-hub", "serve", "--mode", "cloud", "--host", "0.0.0.0"]
