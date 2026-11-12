# shellcheck shell=bash
# scripts/smoke.sh 的一项一项探测，跟着插件走。没写的项会 FAIL 并给出写法，不会默认放行。
#
# 变量别叫 state：shellcheck 把这份文件连着 probes.sh 一起分析，probes.sh 自己也读一个 dev.sh 提供的 state；
# 子壳体函数（fn() ( … )）里给 state 赋值，SC2031 就报在 probes.sh 上，CI 红。
#
# Dify 是 sso: none：网关会话之外还有应用自己的账号。探针走和用户第一次打开时同一条接口注册/登录
# 管理员（POST /console/api/setup、/console/api/login），再调应用自己的接口断言身份和数据。
# 管理员凭据记录在 $SMOKE_STATE 的 dify-admin= 行里，data_write / data_check 复用同一账号；
# SMOKE_STATE 整份由套件保存，其他文件不做这个保证。
# 页面：web_assert 从标准输入读页面，命中的确是应用的真实页面时返回 0。
# 身份：identity_check 只证明身份：登录后调应用的 account/profile，断言认出的就是注册的管理员。
# 数据：data_write 建一个带随机标记的应用（POST /console/api/apps），把标记写进 $SMOKE_STATE；
#       data_check 登录后在应用列表里找回这个标记。
# 工具：清单没有 mcp（Dify 不提供 MCP 服务端），这一项由套件按清单自动记 N/A。
# 通知：notify 权限接的是核心发信（SMTP），只发给家里人；探针不等房间消息。

# 应用控制台 API 的基地址（经核心网关）。
_dify_api() { printf '%s/console/api' "$SMOKE_WEB_ORIGIN"; }

# 带核心会话 + Dify 自己会话的 curl。Dify 的 cookie 存独立 jar，不污染套件的核心会话 jar。
# 注意：cookie 认证的请求要带 X-CSRF-Token（= 登录种的 csrf_token cookie，api/constants/__init__.py），
# 而且只能带一次——同一请求带两份同名头，WSGI 合并成 "值,值"，服务端就当 CSRF 不匹配（实测 401）。
# 所以这里不自动加，调用处按需自己写一个。
_dify_curl() {
  local jar="$1"; shift
  curl -fsS --noproxy '*' -b "$SMOKE_JAR" -b "$jar" -c "$jar" "$@"
}

_dify_jar() {
  mktemp "${SMOKE_STATE%/*}/dify-jar-XXXXXX"
}

# 从 cookie jar（Netscape 格式，tab 分隔）里取一个 cookie 的值。
_dify_cookie() { # <jar> <名字>
  awk -F'\t' -v n="$2" '$6 == n {v = $7} END {print v}' "$1"
}

# 从 $SMOKE_STATE 读 dify-admin=邮箱:密码（没有就输出空）。
_dify_creds_read() {
  grep -m1 '^dify-admin=' "$SMOKE_STATE" 2>/dev/null | cut -d= -f2-
}

# 生成一份合法的管理员凭据（Dify 密码要求字母加数字、8 位以上）。
_dify_creds_make() {
  local rand
  rand="$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')"
  printf 'probe-%s@wonton.internal:pw-%s' "$rand" "$rand"
}

# 没设置过就注册管理员（幂等：已设置直接跳过）。
_dify_ensure_setup() {
  local jar step creds body
  jar="$(_dify_jar)" || return 1
  step="$(_dify_curl "$jar" "$(_dify_api)/setup" | jq -r .step)" || {
    echo "读 /console/api/setup 失败"
    rm -f "$jar"
    return 1
  }
  if [[ "$step" == "not_started" ]]; then
    creds="$(_dify_creds_read)"
    [[ -n "$creds" ]] || creds="$(_dify_creds_make)"
    body="$(jq -rn --arg creds "$creds" '($creds | split(":")) as $p |
      {email:$p[0], name:"probe", password:$p[1], language:"zh-Hans"} | tojson')"
    if ! _dify_curl "$jar" -X POST "$(_dify_api)/setup" \
        -H 'Content-Type: application/json' -d "$body" >/dev/null; then
      echo "注册管理员失败（POST /console/api/setup）"
      rm -f "$jar"
      return 1
    fi
    # 记下凭据：SMOKE_STATE 里已有就不再追加（幂等）。
    [[ -n "$(_dify_creds_read)" ]] || printf 'dify-admin=%s\n' "$creds" >>"$SMOKE_STATE"
  elif [[ -z "$(_dify_creds_read)" ]]; then
    echo "应用已设置过管理员，但 SMOKE_STATE 里没有凭据，无法登录"
    rm -f "$jar"
    return 1
  fi
  rm -f "$jar"
}

# 登录应用，往 jar 里写 Dify 的会话 cookie。请求本身带套件的核心会话，网关才放行。
_dify_login() { # <jar>
  local jar="$1" creds body
  creds="$(_dify_creds_read)"
  if [[ -z "$creds" ]]; then
    echo "SMOKE_STATE 里没有 dify-admin= 凭据（identity_check 应先跑）"
    return 1
  fi
  body="$(jq -rn --arg creds "$creds" '($creds | split(":")) as $p |
    {email:$p[0], password:($p[1] | @base64), remember_me:true} | tojson')"
  # Dify 1.19 的登录接口把 password 当 base64 解码（网页端先编码再发；setup 收的是原文，键名也是原文 password），
  # 见 api/libs/encryption.py 和 controllers/console/wraps.py 的 decrypt_password_field。
  _dify_curl "$jar" -X POST "$(_dify_api)/login" \
    -H 'Content-Type: application/json' -d "$body" >/dev/null || {
    echo "登录失败（POST /console/api/login），账号：${creds%%:*}"
    return 1
  }
  grep -q 'access_token' "$jar" || { echo "登录响应里没有会话 cookie"; return 1; }
}

web_assert() { grep -q 'Dify'; }

identity_check() {
  local jar profile email expected rc=0
  _dify_ensure_setup || return 1
  jar="$(_dify_jar)" || return 1
  _dify_login "$jar" || { rm -f "$jar"; return 1; }
  # cookie 认证的读请求也要 CSRF（实测 GET /account/profile 缺了报 401）。
  if ! profile="$(_dify_curl "$jar" -H "X-CSRF-Token: $(_dify_cookie "$jar" csrf_token)" \
    "$(_dify_api)/account/profile")"; then
    echo "account/profile 请求失败"
    rc=1
  else
    email="$(jq -r '.email // empty' <<<"$profile")"
    expected="$(_dify_creds_read | cut -d: -f1)"
    if [[ -z "$email" ]]; then
      echo "account/profile 没回 email：$(head -c 200 <<<"$profile")"
      rc=1
    elif [[ "$email" != "$expected" ]]; then
      echo "认出的账号不是注册的管理员：$email != $expected"
      rc=1
    fi
  fi
  rm -f "$jar"
  return "$rc"
}

data_write() {
  local jar marker body app_id
  _dify_ensure_setup || return 1
  jar="$(_dify_jar)" || return 1
  _dify_login "$jar" || { rm -f "$jar"; return 1; }
  marker="probe-$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')"
  body="$(jq -rn --arg marker "$marker" '{name:$marker, mode:"chat"} | tojson')"
  # cookie 登录的写请求要带 X-CSRF-Token（值就是登录时种下的 csrf_token cookie）。
  # 带上响应正文一起诊断：失败时 jq 取不到 id，把原文打进日志（401/422 的 message 写得很具体）。
  app_resp="$(_dify_curl "$jar" -X POST "$(_dify_api)/apps" \
    -H 'Content-Type: application/json' \
    -H "X-CSRF-Token: $(_dify_cookie "$jar" csrf_token)" \
    -d "$body" || true)"
  app_id="$(jq -r '.id // empty' <<<"$app_resp")"
  if [[ -z "$app_id" ]]; then
    echo "创建应用失败（POST /console/api/apps）：$(head -c 300 <<<"$app_resp")"
    rm -f "$jar"
    return 1
  fi
  # 覆盖写：保住 dify-admin= 行（data_check 还要用同一账号登录），再写标记。
  # 先读后写：重定向先截断文件，_dify_creds_read 再读就只剩空（实测凭据行会丢）。
  creds_line="$(_dify_creds_read | sed 's/^/dify-admin=/')"
  { [[ -n "$creds_line" ]] && printf '%s\n' "$creds_line"; printf 'marker=%s\napp-id=%s\n' "$marker" "$app_id"; } >"$SMOKE_STATE"
  rm -f "$jar"
}

data_check() {
  local jar marker names
  marker="$(grep -m1 '^marker=' "$SMOKE_STATE" | cut -d= -f2-)"
  if [[ -z "$marker" ]]; then
    echo "SMOKE_STATE 里没有标记（data_write 应先跑）：$(head -c 120 "$SMOKE_STATE" 2>/dev/null)"
    return 1
  fi
  jar="$(_dify_jar)" || return 1
  _dify_login "$jar" || { rm -f "$jar"; return 1; }
  names="$(_dify_curl "$jar" -H "X-CSRF-Token: $(_dify_cookie "$jar" csrf_token)" \
    "$(_dify_api)/apps?page=1&limit=100" | jq -r '.data[]?.name // empty' 2>/dev/null)" || names=""
  rm -f "$jar"
  if grep -qxF "$marker" <<<"$names"; then
    return 0
  fi
  echo "应用列表里找不到标记 $marker，看到的：$(printf '%s' "$names" | head -5 | paste -sd, -)"
  return 1
}
