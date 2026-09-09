FROM mcr.microsoft.com/playwright/python:v1.58.0-jammy

WORKDIR /app

# ---- System deps ----
RUN apt-get update && apt-get install -y \
    xvfb \
    curl \
    unzip \
    gcc \
    build-essential \
    libffi-dev \
    libssl-dev \
    wget \
    fonts-liberation \
    libglib2.0-0 \
    libnss3 \
    libatk-bridge2.0-0 \
    libatk1.0-0 \
    libcups2 \
    libdrm2 \
    libxkbcommon0 \
    libxcomposite1 \
    libxdamage1 \
    libxrandr2 \
    libgbm1 \
    libasound2 \
    libxshmfence1 \
    libx11-xcb1 \
    libxext6 \
    libxfixes3 \
    ca-certificates \
    gnupg \
    && rm -rf /var/lib/apt/lists/*

# ---- Install Google Chrome (REQUIRED for SeleniumBase UC) ----
RUN wget -q -O - https://dl.google.com/linux/linux_signing_key.pub | gpg --dearmor -o /usr/share/keyrings/google.gpg \
    && echo "deb [arch=amd64 signed-by=/usr/share/keyrings/google.gpg] http://dl.google.com/linux/chrome/deb/ stable main" \
       > /etc/apt/sources.list.d/google-chrome.list \
    && apt-get update \
    && apt-get install -y google-chrome-stable \
    && rm -rf /var/lib/apt/lists/*

# ---- Python deps ----
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt \
    && pip install --no-cache-dir \
        playwright-stealth \
        selenium-stealth \
        undetected-chromedriver \
        scrapy

# ---- Ensure Playwright browsers ----
RUN playwright install --with-deps chromium

# ---- SeleniumBase driver ----
RUN seleniumbase install chromedriver

# ---- AWS CLI v2 ----
RUN curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip \
    && unzip /tmp/awscliv2.zip -d /tmp \
    && /tmp/aws/install \
    && rm -rf /tmp/awscliv2.zip /tmp/aws

# ---- App ----
COPY . .
RUN chmod +x entrypoint.sh

ENV PYTHONUNBUFFERED=1
ENV DISPLAY=:99

CMD ["./entrypoint.sh"]