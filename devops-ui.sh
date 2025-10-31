#!/bin/bash
set -e



# === DETERMINE BASE PATHS ===
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
BASE_DIR="/opt/devops-ui"
DOMAIN="vasscomputer.co.in"
TOKEN_FILE="${SCRIPT_DIR}/github_token.txt"
REPO_FILE="${SCRIPT_DIR}/repos.txt"


# === LOAD GITHUB TOKEN ===
if [ ! -f "$TOKEN_FILE" ]; then
  echo "❌ Token file $TOKEN_FILE not found."
  exit 1
fi

source "$TOKEN_FILE"

if [ -z "$USERNAME" ] || [ -z "$TOKEN" ]; then
  echo "❌ USERNAME or TOKEN missing in $TOKEN_FILE"
  exit 1
fi

# === INSTALL DEPENDENCIES ===
echo "[+] Installing dependencies..."
sudo apt update -y
sudo apt install -y python3 python3-pip python3-venv nginx git certbot python3-certbot-nginx python3-gunicorn -y

# === SETUP DIRECTORY ===
sudo mkdir -p "$BASE_DIR"
sudo chown "$USER":"$USER" "$BASE_DIR"

# === CLONE AND DEPLOY EACH REPO ===
cd "$BASE_DIR"

while read repo port branch; do
  [ -z "$repo" ] && continue
  echo ""
  echo "[+] Setting up $repo (branch: $branch) on port $port"

  # Clone or update repo
  if [ -d "$repo/.git" ]; then
    echo "   → Repo exists, pulling latest from $branch..."
    cd "$repo"
    git fetch origin
    git checkout "$branch" || git checkout -b "$branch" origin/"$branch"
    git pull origin "$branch"
    cd ..
  else
    echo "   → Cloning repository ($branch branch)..."
    git clone -b "$branch" https://${USERNAME}:${TOKEN}@github.com/${USERNAME}/${repo}.git
  fi

  cd "$repo"

  # Create Python virtual environment
  python3 -m venv venv
  source venv/bin/activate

  # Install dependencies
  if [ -f "requirements.txt" ]; then
    pip install -r requirements.txt
  fi
  deactivate

  # Create systemd service
  SERVICE_FILE="/etc/systemd/system/${repo}.service"
  echo "[+] Creating systemd service: ${repo}.service"

  sudo bash -c "cat > $SERVICE_FILE" <<EOF
[Unit]
Description=${repo} Service
After=network.target

[Service]
User=$USER
WorkingDirectory=${BASE_DIR}/${repo}
ExecStart=${BASE_DIR}/${repo}/venv/bin/gunicorn --bind 127.0.0.1:${port} ${repo}:app
Restart=always

[Install]
WantedBy=multi-user.target
EOF

  sudo systemctl daemon-reload
  sudo systemctl enable "${repo}.service"
  sudo systemctl restart "${repo}.service"

  cd "$BASE_DIR"
done < "$REPO_FILE"

# === CREATE NGINX CONFIGURATION ===
echo ""
echo "[+] Creating Nginx config..."
NGINX_CONF="/etc/nginx/sites-available/devops-ui.conf"

sudo bash -c "cat > $NGINX_CONF" <<EOF
server {
    listen 80;
    server_name ${DOMAIN};

EOF

while read repo port branch; do
  [ -z "$repo" ] && continue
  path="/${repo/-ui/}/"
  cat <<BLOCK | sudo tee -a $NGINX_CONF >/dev/null
    location ${path} {
        proxy_pass http://127.0.0.1:${port}/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }

BLOCK
done < "$REPO_FILE"

sudo bash -c "echo '}' >> $NGINX_CONF"
sudo ln -sf $NGINX_CONF /etc/nginx/sites-enabled/devops-ui.conf
sudo nginx -t && sudo systemctl reload nginx

# === ENABLE HTTPS ===
echo ""
echo "[+] Enabling HTTPS with Let's Encrypt..."
sudo certbot --nginx -d ${DOMAIN} --non-interactive --agree-tos -m admin@${DOMAIN} || true

echo ""
echo "✅ Setup complete! Access your UIs at:"
while read repo port branch; do
  [ -z "$repo" ] && continue
  echo "   https://${DOMAIN}/${repo/-ui/}/"
done < "$REPO_FILE"
