FROM ghcr.io/kubeflow/kubeflow/notebook-servers/jupyter-scipy:v1.10.0

# Install jupyter-ai, langchain-google-genai, Ray and kubernetes SDK
RUN pip install --no-cache-dir \
    jupyter-ai \
    langchain-google-genai \
    "ray[default]" \
    kubernetes \
    pyyaml \
    google-cloud-storage

# Install gemini-cli and kubectl CLI (requires root)
USER root
RUN curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl" && \
    chmod +x kubectl && \
    mv kubectl /usr/local/bin/

RUN npm install -g @google/gemini-cli

# Create dummy config files in /tmp_home/jovyan/.gemini/ to satisfy jupyter-ai-acp-client check.
# s6-overlay will copy them to /home/jovyan/.gemini/ at startup.
RUN mkdir -p /tmp_home/jovyan/.gemini && \
    echo '{}' > /tmp_home/jovyan/.gemini/settings.json && \
    echo '{}' > /tmp_home/jovyan/.gemini/oauth_creds.json && \
    chown -R 1000:100 /tmp_home/jovyan/.gemini

# Switch back to default user
USER 1000
