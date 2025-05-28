#!/bin/bash
set -e

REG_HOME="$HOME/registry"
CONFIG_YML="$REG_HOME/config/config.yml"
CLEAN_SCRIPT="$REG_HOME/cleanup_all.sh"
CRON_MARKER="# docker-registry-cleanup-task"

echo "🚧 创建目录结构..."
mkdir -p "$REG_HOME"/{data,config}

echo "📝 创建配置文件 config.yml..."
cat <<EOF > "$CONFIG_YML"
version: 0.1
log:
  fields:
    service: registry
storage:
  filesystem:
    rootdirectory: /var/lib/registry
  delete:
    enabled: true
http:
  addr: :5000
  headers:
    X-Content-Type-Options: [nosniff]
EOF

echo "🚀 启动 Docker Registry..."
docker rm -f registry >/dev/null 2>&1 || true
docker run -d --name registry \
  -p 5000:5000 \
  -v "$REG_HOME/data":/var/lib/registry \
  -v "$CONFIG_YML":/etc/docker/registry/config.yml \
  registry:2

echo "🧹 创建多仓库清理脚本..."
cat <<'EOS' > "$CLEAN_SCRIPT"
#!/bin/bash
set -e

REGISTRY="localhost:5000"
KEEP=5

echo "📦 获取所有仓库..."
REPO_LIST=$(curl -s http://$REGISTRY/v2/_catalog | jq -r '.repositories[]')

for REPO in $REPO_LIST; do
  echo "🔍 处理仓库: $REPO"

  TAGS=$(curl -s "http://$REGISTRY/v2/$REPO/tags/list" | jq -r '.tags[]?' | sort -r)
  if [ -z "$TAGS" ]; then
    echo "⚠️  仓库 $REPO 无 tag，跳过"
    continue
  fi

  declare -A DIGEST_TO_TAGS
  declare -A TAG_TO_DIGEST
  ALL_DIGESTS=()

  for TAG in $TAGS; do
    DIGEST=$(curl -sI -H "Accept: application/vnd.docker.distribution.manifest.v2+json" \
      "http://$REGISTRY/v2/$REPO/manifests/$TAG" | grep Docker-Content-Digest | awk '{print $2}' | tr -d $'\r')

    if [ -n "$DIGEST" ]; then
      TAG_TO_DIGEST[$TAG]=$DIGEST
      DIGEST_TO_TAGS[$DIGEST]="${DIGEST_TO_TAGS[$DIGEST]} $TAG"
    fi
  done

  ALL_DIGESTS=($(for TAG in $TAGS; do echo "${TAG_TO_DIGEST[$TAG]}"; done | awk '!seen[$0]++'))

  KEEP_DIGESTS=("${ALL_DIGESTS[@]:0:$KEEP}")

  echo "✅ 保留 digest（$REPO）："
  for D in "${KEEP_DIGESTS[@]}"; do echo " - $D"; done

  for DIGEST in "${ALL_DIGESTS[@]}"; do
    IS_KEEP=0
    for KD in "${KEEP_DIGESTS[@]}"; do
      [ "$DIGEST" == "$KD" ] && IS_KEEP=1 && break
    done

    if [ $IS_KEEP -eq 1 ]; then
      continue
    fi

    echo "🗑️  删除仓库 $REPO 中的 digest: $DIGEST"
    curl -s -X DELETE "http://$REGISTRY/v2/$REPO/manifests/$DIGEST"
  done
done

echo "🚮 执行 Registry 垃圾回收..."
#docker stop registry
#docker run --rm -v /home/ec2-user/registry/data:/var/lib/registry \
#  -v /home/ec2-user/registry/config/config.yml:/etc/docker/registry/config.yml \
#  registry:2 garbage-collect /etc/docker/registry/config.yml
#docker start registry

echo "✅ 所有仓库清理完毕"
EOS

chmod +x "$CLEAN_SCRIPT"

echo "📅 设置定时任务（每天凌晨3点自动清理 + 垃圾回收）..."

# 删除旧的清理任务（避免重复）
crontab -l | grep -v "$CRON_MARKER" > /tmp/cron_tmp || true

# 添加新任务
echo "0 3 * * * $CLEAN_SCRIPT && docker stop registry && \
docker run --rm -v $REG_HOME/data:/var/lib/registry \
-v $CONFIG_YML:/etc/docker/registry/config.yml \
registry:2 garbage-collect /etc/docker/registry/config.yml && docker start registry $CRON_MARKER" >> /tmp/cron_tmp

# 应用 crontab
crontab /tmp/cron_tmp
rm -f /tmp/cron_tmp

echo "✅ 安装部署完成！"
echo "✅ Registry 运行在 http://localhost:5000/"
echo "✅ 清理脚本路径: $CLEAN_SCRIPT"
