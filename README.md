# ppmmxDocker

一键在自己的云上部署 [ppmmx](https://github.com/ppcdn-org/ppmmx) 节点，组建自己的 LiveCDN —— 设计见
ppcdn 主仓库的 `docs/roadmap/ppcdn-ppmmx-license-selfhost.zh-CN.md`。
按 **$2.5 / 实例 / 天** 计费，不限部署时长、不限节点规模；欠费自动暂停，充值自动恢复。

## 快速开始

1. 在 [PPCDN 控制台](https://console.pp-cdn.org) 的 **ppmmx 节点** 标签页点"新增 ppmmx 节点"，
   填节点名并选类型（`standalone` / `origin` / `record` / `edge`），创建成功后会拿到一对
   **Node Secret** 和 **License Code**（随时可在节点列表里复制）。
2. 在你自己的服务器上跑一键部署脚本（见下方「一键部署脚本」），只需要这两个值。

就这样——不需要手动碰 YAML、不需要自己装 Docker、甚至不需要自己 `git clone`。

## 一键部署脚本

脚本由**你自己**在目标服务器上执行（不是我们代执行）。只需要上一步拿到的
Node Secret 和 License Code 这两个值，其余全部有默认值。

### Linux（Ubuntu / Debian / CentOS / RHEL 系）

```bash
curl -fsSL https://raw.githubusercontent.com/ppcdn-org/ppmmxDocker/main/deploy.sh -o deploy.sh
chmod +x deploy.sh
./deploy.sh --license-code lic_xxx --node-secret nsk_xxx
```

没有 Docker 会自动装（`get.docker.com` 官方脚本）；当前目录没有这个仓库会自动
`git clone` 到 `./ppmmxDocker`；没指定 `--webrtc-host` 会自动探测这台机器的公网 IP。
完整参数（`--role`/`--control-url`/`--webrtc-host`/各端口…）见 `./deploy.sh --help`。

### Windows（需要先自己装好 [Docker Desktop](https://www.docker.com/products/docker-desktop/) 并启动它）

```powershell
Invoke-WebRequest -Uri https://raw.githubusercontent.com/ppcdn-org/ppmmxDocker/main/deploy.ps1 -OutFile deploy.ps1
.\deploy.ps1 -LicenseCode lic_xxx -NodeSecret nsk_xxx
```

Docker Desktop 的安装通常需要交互确认 + 重启，脚本不会替你自动装；没装/没启动会提示下载链接后退出。
其余行为和 Linux 版一致。完整参数见 `Get-Help .\deploy.ps1 -Full`。

### 两个脚本做的事都一样

1. 确认 Docker 可用（Linux 自动装；Windows 要求你已经装好 Docker Desktop）。
2. 如果当前目录不是本仓库的 clone，自动拉取一份。
3. 没给 `--webrtc-host`/`-WebrtcHost` 就自动探测这台机器的公网 IP。
4. 生成 `.env`（含你的凭据，权限收紧为仅自己可读）。
5. `docker compose up -d --build` 拉起节点。

跑完之后，看到日志里出现 `MMX control connected`（无 `registration rejected`），
回到控制台的 ppmmx 节点列表，对应节点状态应变为「运行中」。

### 想手动控制每一步？

脚本本质上就是把下面这几步自动化了，你也可以照着手动做（比如需要先改 YAML 再启动）：

```bash
git clone https://github.com/ppcdn-org/ppmmxDocker.git
cd ppmmxDocker
cp .env.example .env
# 编辑 .env：填入 MMX_NODE_SECRET / MMX_LICENSE_CODE，按需要的角色设置 MMX_ROLE，
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
| `standalone` | 独立组网：单实例同时接 OBS 直推（WHIP/SRT）又直接给观众提供 WHEP 播放，不转发、不回源、不参与跨节点调度。单机自建的默认选择。 |
| `origin` | 接入节点：接受推流，可选择转发给你自己的 `record`/`edge` 节点（多节点自建时用）。 |
| `edge` | 分发节点：被动接收你自己 `origin` 的转发，服务观众，不接直推。 |
| `record` | 录像节点：被动接收你自己 `origin` 的转发并落盘录像，不服务观众播放。 |

单机场景直接用 `standalone`。多节点自建（如一台 origin + 多台 edge 扩容）需要额外在
`origin` 节点的配置里打开 `forwardMmxEnable` 并填 `forwardMmxTargets`——参见
`conf/origin.yml` 里的注释，以及「自定义配置」一节。

## 端口与防火墙

容器内部端口对所有角色统一（Docker 下每个节点都是独立容器，不像裸机部署需要为
同机多角色互相让开端口）：

| 端口 | 协议 | 用途 | 必须公网可达 |
| --- | --- | --- | --- |
| 8888 | TCP | WebRTC 信令 (WHIP/WHEP HTTP) | standalone/origin/edge：是；record：否 |
| 8188 | UDP | WebRTC ICE（媒体数据，流量主体） | standalone/origin/edge：是；record：否 |
| 8080 | TCP | Admin 管理界面 | 否（建议只在内网/VPN 访问，或用防火墙限制来源 IP） |
| 9996 | TCP | 内部控制 API | 否 |
| 7890 | UDP | SRT 推流入口（仅 standalone/origin 开启） | 仅需要 SRT 推流时 |

`.env` 里的 `MMX_*_PORT` 只改**宿主机侧**映射的端口号；容器内部端口不变。同一台主机上
跑多个节点时，给每个节点的 `.env` 分别改宿主机端口（如 `MMX_WEBRTC_PORT=8898`）、用不同的
`docker compose -p <project-name>` 隔离，或分别放进不同目录各跑各的 compose。

## 环境变量覆盖

ppmmx 的配置字段可以通过环境变量覆盖 YAML 文件里的值（`MTX_<JSON 字段大写>` 规则，见 ppmmx
仓库 `internal/conf/env`），`docker-compose.yml` 已经把最常用的几个接到了 `.env`：

| `.env` 变量 | 覆盖的配置项 | 说明 |
| --- | --- | --- |
| `MMX_NODE_SECRET` | WS 鉴权凭证 | 必填，控制台创建节点时生成 |
| `MMX_LICENSE_CODE` | 授权码 | 必填，控制台创建节点时生成；启用授权心跳/看门狗（每 0.5h 上报，300s 无应答自动退出） |
| `MMX_ROLE` | 选用 `conf/<role>.yml` 哪一份模板 | `standalone` \| `origin` \| `edge` \| `record` |
| `MMX_CONTROL_URL` | `mmxControlURL` | ppcenter 的 WS 控制面地址 |
| `MMX_NODE_REGION` | `mmxNodeRegion` | 自由文本，仅展示 |
| `MMX_NODE_CAPACITY` | `mmxNodeCapacity` | 最大并发推流+播放路数 |
| `MMX_WEBRTC_BASE_URL` | `mmxWebRTCBaseURL` | 本机公网可达地址，standalone/origin/edge 必填 |
| `MMX_PUBLISH_URL` | `mmxPublishURL` | 仅 origin 用，一般留空即可 |

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

`bin/mmx-linux-amd64` 是**提交进这个仓库**的预编译二进制（和 `dist/` 不一样，`dist/` 继续
`.gitignore` 掉，只是本地构建的临时产物）——这是故意的：ppmmx 自己的源码仓库是**私有的**，
客户的机器没有权限 `git clone` 它来自己编译，所以必须由维护者预先编译好、随这个公开仓库
一起分发；`Dockerfile`/`deploy.sh`/`deploy.ps1` 都只认 `bin/`，不会去碰 ppmmx 私有仓库。

每次 ppmmx 有改动需要让自建客户用上，维护者在本机跑：

```bash
# 1. 和 ppmmx 源码仓库放在同一个父目录下（即 ../ppmmx 能找到 go.mod）
git clone https://github.com/ppcdn-org/ppmmx.git ../ppmmx   # 已 clone 过就跳过，拉最新改动即可

# 2. 交叉编译并发布：dist/mmx-linux-amd64 -> bin/mmx-linux-amd64
./build.sh --release

# 3. 按脚本提示的 git 命令提交 + 推送
git add bin/mmx-linux-amd64
git commit -m "release: ppmmx vX.Y.Z"
git push
```

`PPMMX_SRC` 环境变量可以指向别的路径：`PPMMX_SRC=/path/to/ppmmx ./build.sh --release`。

**当前只产出 `linux/amd64`**：ppmmx 仓库的 `internal/staticsources/rpicamera`（上游 MediaMTX
遗留的树莓派摄像头支持，与 ppmmx 的云节点场景无关）在交叉编译 `arm64` 时会因缺失
`go:embed` 目录而失败，这是 ppmmx 仓库本身的已知问题，不是 ppmmxDocker 的限制——
修复后 `build.sh`/`Dockerfile` 的 `ARG TARGETARCH` 即可直接支持 arm64，无需改这两个文件。
Docker Desktop for Windows/Mac 底层也是跑 Linux 容器，所以不需要为 Windows/macOS 宿主机
单独编译 ppmmx 本身——`deploy.ps1` 只是帮 Windows 用户跑 `docker compose`，容器内部
用的仍然是这份 `linux/amd64` 二进制。

**未来**：ppmmx 正式发布公开 GitHub Release 后，`build.sh`/`Dockerfile` 可以改为直接下载
发布的二进制，不再要求维护者本机有 ppmmx 私有仓库的访问权限。

## 故障排查

- **日志里 `registration rejected` / `invalid or disabled nodeSecret`**：`MMX_NODE_SECRET`
  填错，或节点在控制台已被删除。回控制台核对/重新生成。
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
