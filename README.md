# ppmmxDocker

一键在自己的云上部署 [ppmmx](https://github.com/ppcdn-org/ppmmx) 节点，组建自己的 LiveCDN —— 设计见
ppcdn 主仓库的 `docs/roadmap/ppcdn-ppmmx-license-selfhost.zh-CN.md`。
按 **$2.5 / 实例 / 天** 计费，不限部署时长、不限节点规模；欠费自动暂停，充值自动恢复。

## 快速开始

1. 在 [PPCDN 控制台](https://console.pp-cdn.org) 的 **ppmmx 节点** 标签页点"新增 ppmmx 节点"，
   填节点名并选类型（`standalone` / `origin` / `record` / `edge`），创建成功后会拿到
   **License Code**（随时可在节点列表里复制）。
2. 在你自己的服务器上跑一键部署脚本（见下方「一键部署脚本」），只需要这一个值——
   节点类型（第 1 步选的）已经落在 ppcenter，部署脚本会凭 License Code 自动查回来，
   不用你再填一遍。

就这样——不需要手动碰 YAML、不需要自己装 Docker、甚至不需要自己 `git clone`。

## 一键部署脚本

脚本由**你自己**在目标服务器上执行（不是我们代执行）。只需要上一步拿到的
License Code 这一个值，其余全部有默认值或自动解析。

### Linux（Ubuntu / Debian / CentOS / RHEL 系）

```bash
curl -fsSL https://raw.githubusercontent.com/ppcdn-org/ppmmxDocker/main/deploy.sh -o deploy.sh
chmod +x deploy.sh
./deploy.sh --license-code lic_xxx
```

没有 Docker 会自动装（`get.docker.com` 官方脚本）；当前目录没有这个仓库会自动
`git clone` 到 `./ppmmxDocker`；没指定 `--webrtc-host` 会自动探测这台机器的公网 IP。
完整参数（`--role`/`--control-url`/`--webrtc-host`/各端口…）见 `./deploy.sh --help`。

### Windows（需要先自己装好 [Docker Desktop](https://www.docker.com/products/docker-desktop/) 并启动它）

```powershell
Invoke-WebRequest -Uri https://raw.githubusercontent.com/ppcdn-org/ppmmxDocker/main/deploy.ps1 -OutFile deploy.ps1
.\deploy.ps1 -LicenseCode lic_xxx
```

Docker Desktop 的安装通常需要交互确认 + 重启，脚本不会替你自动装；没装/没启动会提示下载链接后退出。
其余行为和 Linux 版一致。完整参数见 `Get-Help .\deploy.ps1 -Full`。

### 两个脚本做的事都一样

1. 凭 `--license-code`/`-LicenseCode` 向 ppcenter 查询这个节点的类型（`standalone`/
   `origin`/`edge`/`record`）——创建节点时已经定下来了，不需要你手动再选一次；
   如果你很确定想跳过这步网络请求，可以用 `--role`/`-Role` 直接指定。
2. 确认 Docker 可用（Linux 自动装；Windows 要求你已经装好 Docker Desktop）。
3. 如果当前目录不是本仓库的 clone，自动拉取一份。
4. 没给 `--webrtc-host`/`-WebrtcHost` 就自动探测这台机器的公网 IP。
5. 生成 `.env`（含你的凭据，权限收紧为仅自己可读）。
6. `docker compose up -d --build` 拉起节点。

跑完之后，看到日志里出现 `MMX control connected`（无 `registration rejected`），
回到控制台的 ppmmx 节点列表，对应节点状态应变为「运行中」。

### 想手动控制每一步？

脚本本质上就是把下面这几步自动化了，你也可以照着手动做（比如需要先改 YAML 再启动）；
手动走这条路时没有自动查角色这一步，`MMX_ROLE` 要照你创建节点时选的类型自己填对：

```bash
git clone https://github.com/ppcdn-org/ppmmxDocker.git
cd ppmmxDocker
cp .env.example .env
# 编辑 .env：填入 MMX_LICENSE_CODE，按创建节点时选的类型设置 MMX_ROLE，
# 并把 MMX_WEBRTC_BASE_URL 改成这台机器的公网 IP 或域名
vi .env
docker compose up -d --build
docker compose logs -f
```

角色相关的默认配置已经打进镜像的 `conf/<role>.yml`，`.env` 里的值通过环境变量在
启动时覆盖进去（见下方「环境变量覆盖」）。

## 节点类型怎么选

| 类型 | 适用场景 |
| --- | --- |
| `standalone` | 独立组网：单实例同时接 OBS 直推（WHIP/SRT）又直接给观众提供 WHEP 播放，不转发、不回源、不参与跨节点调度。同时支持按场次录像（见下文「录像 API 与回放地址」）。单机自建的默认选择。 |
| `origin` | 接入节点：接受推流，可选择转发给你自己的 `record`/`edge` 节点（多节点自建时用）。 |
| `edge` | 分发节点：被动接收你自己 `origin` 的转发，服务观众，不接直推。 |
| `record` | 录像节点：被动接收你自己 `origin` 的转发并落盘录像，不服务观众播放；录像 API 与回放地址见下文「录像 API 与回放地址」。 |

单机场景直接用 `standalone`。多节点自建（如一台 origin + 多台 edge 扩容）需要额外在
`origin` 节点的配置里打开 `forwardMmxEnable` 并填 `forwardMmxTargets`——参见
`conf/origin.yml` 里的注释，以及「自定义配置」一节。

## 录像 API 与回放地址

`standalone` 和 `record` 节点支持按场次录像：业务后端在一场开始/结束时各调一次
`POST /api/record/split`，节点把这一场切成独立 mp4，**文件保留在节点本机**
（容器内 `data/recordings/`，docker 卷 `mmx-data`），并在**结束那次调用的响应里
直接返回回放地址**（`data.playbackUrls[].url`）。

**调用主机必须是你自己的节点地址**，也就是该节点 `.env` 里的 `MMX_WEBRTC_BASE_URL`
（`https://mmx-xxxx.rent.pp-cdn.org` 或 `http://<节点公网IP>:8888`）：

```bash
curl -X POST "$MMX_WEBRTC_BASE_URL/api/record/split" ...   # 签名与完整示例见 example/recordApi/
```

> **不要使用 `record.pp-cdn.org`。** 那是 PPCDN 托管的录像节点，只录推到托管节点上的流，
> 看不到你机器上的流；`example/recordApi/` 里的示例客户端会直接拒绝它。

要点：

- 流必须推到**这台节点**上，流名 `{appId}/{tableId}-{view}`；签名用控制台里该 `appId` 自己的 `appSecret`。
- 回放地址是节点自己提供的链接，**不鉴权、不设过期**，可直接放进 `<video src>`；
  文件还在节点上就能播放。
- **文件保留 10 天，过期由 mmx 自带的录像清理自动删除**（模板里 `recordDeleteAfter: 240h`，
  按文件最后修改时间计算），删除后同一地址返回 404；要保留更久就调大这个值。
  磁盘容量要按「每天录像量 × 保留天数」自行规划。
- 想额外上传到对象存储，在 `.env` 里填 `S3_*`（见 `.env.example`「录像上传」）；留空则只保留在本机。
- 完整接口说明（字段、签名、状态码、回放地址字段）见 `example/recordApi/README.md`。

## 端口与防火墙

容器内部端口对所有角色统一（Docker 下每个节点都是独立容器，不像裸机部署需要为
同机多角色互相让开端口）：

| 端口 | 协议 | 用途 | 必须公网可达 |
| --- | --- | --- | --- |
| 8888 | TCP | WebRTC 信令 (WHIP/WHEP HTTP)；同时承载录像 API 与回放地址 | standalone/origin/edge：是；record：调用录像 API / 打开回放地址的一方要能访问到 |
| 8188 | UDP | WebRTC ICE（媒体数据，流量主体） | standalone/origin/edge：是；record：否 |
| 8080 | TCP | Admin 管理界面 | 否（建议只在内网/VPN 访问，或用防火墙限制来源 IP） |
| 9996 | TCP | 内部控制 API | 否 |
| 7890 | UDP | SRT 推流入口（仅 standalone/origin 开启） | 仅需要 SRT 推流时 |
| 1935 | TCP | Enhanced RTMP (ERTMP) 推流入口（仅 origin 开启） | 仅需要 ERTMP 推流时 |
| 80, 443 | TCP | HTTPS 播放入口（自动 HTTPS，见下节） | 需要浏览器播放时 |

`.env` 里的 `MMX_*_PORT` 只改**宿主机侧**映射的端口号；容器内部端口不变。同一台主机上
跑多个节点时，给每个节点的 `.env` 分别改宿主机端口（如 `MMX_WEBRTC_PORT=8898`）、用不同的
`docker compose -p <project-name>` 隔离，或分别放进不同目录各跑各的 compose。

## 自动 HTTPS（浏览器播放）

浏览器有 mixed-content 策略：**https 的播放页不允许请求明文 http 的 edge**（推流端是 OBS/ffmpeg 等原生程序，不受此限制；P2P 播放也绕开节点 http，所以只有「edge-only 播放」——例如 HEVC——会踩到）。需要浏览器播放的节点必须让 edge 走 https。`deploy.sh`/`deploy.ps1` 已自动完成，无需手动配置：

1. 部署脚本用 license code 调 ppcenter 的 `POST /v1/ppmmx/provision`，ppcenter 给节点分配一个**固定随机**域名 `mmx-<8位随机>.<平台域名>`，并自动建好 DNS（**灰云** A 记录，指向本机公网 IP；灰云是必须的，橙云会把 WebRTC 的 UDP ICE 代理坏）。
2. 脚本据此生成 `Caddyfile`，并把 `.env` 的 `MMX_WEBRTC_BASE_URL` 设成 `https://<该域名>`。`docker-compose.yml` 里的 `caddy` 容器（host 网络）用该域名**自动申请/续期 Let's Encrypt 证书**，把 443 反代到本机 8888（mmx 自身仍监听明文 8888，供 origin→edge 的 forwardMmx 直连）。
3. 放行 **80、443/tcp**（证书签发 + HTTPS 入口）。

平台未配置 Cloudflare 时该步骤自动跳过，节点继续用明文 http（原生推流不受影响，浏览器播放会被拦）。手动、不走脚本的部署可自行给节点配 https 域名 + 反代，并把 `MMX_WEBRTC_BASE_URL` 设成该 https 地址。

## 公网可达性与多节点转发（WebRTC 候选地址）

WebRTC 建立媒体连接时，双方交换的 ICE 候选地址必须是**对端可达的地址**。默认 Docker
bridge 网络下，容器只会把自己**内网 IP**（172.x）当作候选广播出去，外部观众/发布端
（以及 origin → edge/record 的转发）都连不上——典型症状是转发日志里的
`waiting for connection: deadline exceeded while waiting connection`。两种修法二选一：

- **推荐：单机单节点用 host 网络。** 在 `docker-compose.yml` 的服务里加一行
  `network_mode: host`，并**删掉 `ports:` 段**（host 模式下端口直接绑在宿主机上，`ports`
  被忽略）。容器直接用宿主机网络，ICE 候选就是宿主机真实网卡（含公网 IP），
  模板里的 `webrtcIPsFromInterfaces: true` 即可命中。**`deploy.sh`/`deploy.ps1` 现在会自动完成这一步**：检测到默认（bridge + `ports:`）的 compose 时，就把 `ppmmx` 切到 host 网络并移除 `ports:` 段，保证一键部署出来的节点开箱即可公网收流/播放。
- **保留 bridge + 显式声明公网 ICE 主机。** 复制模板为 `mmx.yml`（见「自定义配置」），把
  `webrtcIPsFromInterfaces` 设为 `false`，并加 `webrtcAdditionalHosts: ["<你的公网IP>"]`。
  这样服务端候选是公网地址；但 **origin → edge/record 的 forwardMmx 是一个 WHIP 客户端**，
  bridge 下它仍会广播容器内网 IP，跨节点转发仍会失败——所以**多节点转发建议直接用 host 网络**。

### 多节点转发（origin → edge/record）

1. 每台节点各自的 `.env` 里填**同一个** `MMX_FORWARD_SECRET`（64 位随机串即可）；
   `docker-compose.yml` 已把它透传进容器。
2. origin 用自定义 `mmx.yml`（见「自定义配置」），打开转发并列出目标节点公网地址：

   ```yaml
   forwardMmxEnable: true
   paths:
     all:
       source: publisher
       sourceOnDemand: false
       forwardMmx: true
       forwardMmxTargets:
         - url: http://<edge公网IP>:8888/{path}/whip
   ```

   `{path}` 由 ppmmx 按实际流路径替换；token 自动取 `.env` 的 `MMX_FORWARD_SECRET`，
   不必写进 YAML。目标端口用对端 WebRTC 的 8888（host 网络下即宿主机 8888）。
3. `edge`/`record` 侧无需额外配置：其模板 `source: publisher` 会接受携带正确
   `Authorization: Bearer <MMX_FORWARD_SECRET>` 的转发。
4. **音频说明**：forwardMmx 走 WebRTC/WHIP，WebRTC 观众也走 WHEP，不支持 AAC，服务端也不转码。因此节点的音频策略是：
   **只有 RTSP / ERTSP 推流接受 AAC，其它协议（SRT、Enhanced RTMP、WHIP、MoQ）只接受 Opus**，
   音频是别的编码（AAC、MP3、AC-3、G.711 等）就**明确拒绝**这次推流（来自本机回环的 CDN ingest 推流除外）：连接被断开，节点日志里有一行明确原因，例如
   `SRT publish rejected: AAC (MPEG-4 Audio) audio is not supported, only Opus audio is accepted (AAC is accepted only on RTSP/ERTSP publishes; ...)`。
   请把推流端的音频编码改成 **Opus**（ppobs 选 SRT / WHIP / ERTMP 时音频编码器本来就只提供 Opus；ffmpeg 用 `-c:a libopus`）。
   传统（非 Enhanced）RTMP 只能承载 AAC，所以不能直接推；请改用 Enhanced RTMP + Opus，或改用 SRT / WHIP。
   RTSP / ERTSP 推流的 AAC 虽然被接受，但转发给其它节点和 WebRTC 播放时会丢弃音频（转发日志 `skipping track N (MPEG-4 Audio)`）。

## 环境变量覆盖

ppmmx 的配置字段可以通过环境变量覆盖 YAML 文件里的值（`MTX_<JSON 字段大写>` 规则，见 ppmmx
仓库 `internal/conf/env`），`docker-compose.yml` 已经把最常用的几个接到了 `.env`：

| `.env` 变量 | 覆盖的配置项 | 说明 |
| --- | --- | --- |
| `MMX_LICENSE_CODE` | 授权码 + WS 鉴权凭证 | 必填，控制台创建节点时生成；既启用授权心跳/看门狗（每 0.5h 上报，300s 无应答自动退出），也可单独作为 REGISTER 的鉴权凭证使用（见下一行） |
| `MMX_NODE_SECRET` | WS 鉴权凭证 | 可选——留空时 `MMX_LICENSE_CODE` 单独就能完成 REGISTER（ppcenter 按授权码反查节点），不需要额外填这个 |
| `MMX_ROLE` | 选用 `conf/<role>.yml` 哪一份模板 | `standalone` \| `origin` \| `edge` \| `record`；deploy.sh/deploy.ps1 会凭 `MMX_LICENSE_CODE` 自动查出来写进 `.env`，只有手动编辑 `.env` 时才需要自己填 |
| `MMX_CONTROL_URL` | `mmxControlURL` | ppcenter 的 WS 控制面地址 |
| `MMX_NODE_REGION` | `mmxNodeRegion` | 自由文本，仅展示 |
| `MMX_NODE_CAPACITY` | `mmxNodeCapacity` | 最大并发推流+播放路数；默认 1000，即软件侧不限制容量，实际以节点硬件能力为准 |
| `MMX_WEBRTC_BASE_URL` | `mmxWebRTCBaseURL` | 本机公网可达地址，standalone/origin/edge 必填；也是**录像 API 的调用地址和回放地址的主机**（见「录像 API 与回放地址」） |
| `MMX_PUBLISH_URL` | `mmxPublishURL` | 仅 origin 用：SRT 推流接入地址，写成 `<公网IP或域名>:<srt-port>`（**不是** WebRTC 端口）。留空会让 SRT 推流得到 `no_healthy_origin`；deploy.sh/deploy.ps1 会为 origin 角色自动填好 |
| `MMX_RTMP_PUBLISH_URL` | `mmxRTMPPublishURL` | 仅 origin 用：Enhanced RTMP (ERTMP) 推流接入地址 `<公网IP或域名>:<rtmp-port>`（依赖 `conf/origin.yml` 里开启的 `rtmp` 服务）。留空则 ERTMP 推流得到 `no_healthy_origin`；deploy 脚本会为 origin 角色自动填好 |
| `MMX_FORWARD_SECRET` | forwardMmx 鉴权 | 仅多节点转发需要：origin 与它转发的 `edge`/`record` 必须填**同一个值**（见「公网可达性与多节点转发」） |
| `S3_BUCKET` / `S3_ACCESS_ID` / `S3_ACCESS_PASS` 等 | 录像上传（环境变量，非 YAML 字段） | 可选，standalone/record：三项都填才会把录像上传到 S3 兼容存储；留空则录像只保留在本机。完整列表见 `.env.example`「录像上传」 |

未覆盖的字段按 `conf/<role>.yml` 里的默认值生效。

## 自定义配置

默认用镜像内置的 `conf/<MMX_ROLE>.yml`。如果需要改默认值覆盖不到的字段（如 `paths`、
`forwardMmx*`、SRT/WebRTC 细调参数），复制对应模板出来改：

```bash
cp conf/standalone.yml mmx.yml   # 按你的角色选对应模板
vi mmx.yml
```

然后在 `docker-compose.yml` 里取消注释挂载这一行：

```yaml
    volumes:
      - ./mmx.yml:/app/mmx.yml:ro
```

挂载了 `/app/mmx.yml` 之后，入口脚本（`docker-entrypoint.sh`）会优先使用它，`MMX_ROLE`
和内置模板都不再生效（`.env` 里的 `MTX_*`/`MMX_NODE_SECRET`/`MMX_LICENSE_CODE` 覆盖仍然生效，
因为那是启动时的环境变量覆盖，与用哪份文件无关）。

## 维护者：如何发布新版本的 ppmmx 二进制

ppmmx 二进制**不再提交进这个仓库**，而是发布成这个公开仓库的 **GitHub Release**：
`Dockerfile` 在构建镜像时从 `releases/latest/download/mmx-linux-amd64` 下载，并用同一个 Release 里的
`mmx-linux-amd64.sha256` 校验。这样仓库不会随版本越涨越大，Release 里也**只保留最新版本**
（发布新版本时会自动删除旧的 Release 和 tag）。ppmmx 自己的源码仓库是**私有的**，客户机器没有权限
`git clone` 来自己编译，所以仍需维护者预先编译好并公开发布。

每次 ppmmx 有改动需要让自建客户用上，维护者在本机跑（需要已登录并有写权限的 GitHub CLI `gh`）：

```bash
# 1. 和 ppmmx 源码仓库放在同一个父目录下（即 ../ppmmx 能找到 go.mod）
git clone https://github.com/ppcdn-org/ppmmx.git ../ppmmx   # 已 clone 过就跳过，拉最新改动即可

# 2. 交叉编译并发布 Release（版本号取 ppmmx 的 internal/core/VERSION，也可以 ./build.sh v1.2.3 --release）
./build.sh --release
```

脚本会：编译 `dist/mmx-linux-amd64` → 生成 `.sha256` → 创建（或覆盖）名为该版本的 Release 并标记为
latest → 删除其它所有旧 Release。`PPMMX_SRC` 可以指向别的 ppmmx 路径，`RELEASE_REPO` 可以改发布到别的仓库。

**客户侧如何升级**：已部署的节点在 `ppmmxDocker` 目录里 `docker compose build --no-cache ppmmx && docker compose up -d ppmmx`
（或重新运行 `deploy.sh`）即可拿到最新 Release；`docker compose up -d --build` 在 Release 没变时会走缓存。
测试自己的构建时可以起一个本地文件服务，再 `docker build --build-arg MMX_BASE_URL=http://host:8000 .`。

**当前只产出 `linux/amd64`**：ppmmx 仓库的 `internal/staticsources/rpicamera`（上游 MediaMTX
遗留的树莓派摄像头支持，与 ppmmx 的云节点场景无关）在交叉编译 `arm64` 时会因缺失
`go:embed` 目录而失败，这是 ppmmx 仓库本身的已知问题，不是 ppmmxDocker 的限制——
修复后只需在 Release 里同时发布 `mmx-linux-arm64` 和对应 `.sha256`，`Dockerfile` 的 `ARG TARGETARCH`
即可直接支持 arm64。Docker Desktop for Windows/Mac 底层也是跑 Linux 容器，所以不需要为 Windows/macOS
宿主机单独编译 ppmmx 本身——`deploy.ps1` 只是帮 Windows 用户跑 `docker compose`，容器内部
用的仍然是这份 `linux/amd64` 二进制。

## 故障排查

- **日志里 `registration rejected` / `invalid or disabled nodeSecret/licenseCode`**：
  `MMX_LICENSE_CODE`（或手动填的 `MMX_NODE_SECRET`）填错，或节点在控制台已被删除。回控制台核对/重新生成。
- **部署脚本报 `could not resolve this license code`**：`--license-code`/`-LicenseCode`
  填错，或这台机器连不通 `--control-url` 对应的 ppcenter；也可以加 `--role`/`-Role`
  直接指定角色，跳过这步自动查询。
- **日志里 `license rejected` 后进程退出**：`MMX_LICENSE_CODE` 填错，或账户欠费（license 被
  软删除）——充值后节点会在下一次上报周期（≤30min）自动恢复，也可以直接重启容器加速生效：
  `docker compose restart`。
- **节点注册成功但播放/推流连不上**：多半是 `MMX_WEBRTC_BASE_URL` 没填成这台机器的公网
  IP/域名，或云厂商安全组/本机防火墙没放开 8888(TCP)/8188(UDP)。
- **查看 admin 管理界面**：`ssh -L 8080:localhost:8080 your-server` 后浏览器打开
  `http://localhost:8080`（不建议直接暴露公网）。

## 验收清单

- [ ] 干净 Ubuntu 主机上 `docker compose up -d --build` 成功拉起容器
- [ ] 日志显示 WS 注册成功，控制台节点状态变为「运行中」
- [ ] 推流/播放可用（WHIP 推流到 `http://<host>:8888/<path>/whip`，WHEP 播放
      `http://<host>:8888/<path>/whep`）
- [ ] 账户欠费后节点自动下线，充值后自动恢复（见上方故障排查）
