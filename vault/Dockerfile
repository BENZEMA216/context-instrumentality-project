FROM python:3.12-slim
WORKDIR /build
COPY pyproject.toml .
COPY context_vault context_vault
COPY skills skills
RUN pip install --no-cache-dir . && useradd --system --create-home --uid 10001 vault && mkdir -p /vault && chown vault /vault
USER vault
ENV CONTEXT_VAULT_DATA=/vault
VOLUME ["/vault"]
EXPOSE 8743
ENTRYPOINT ["context-vault","serve","--container-bind"]
