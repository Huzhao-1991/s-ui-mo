#!/bin/bash

red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
plain='\033[0m'

cur_dir=$(pwd)

#############################################
# Distribution
#
# Everything this script fetches comes from the repository named here. It is
# overridable so a mirror or a private fork needs no edit:
#   SUI_REPO=owner/repo bash install.sh
#############################################
SUI_REPO="${SUI_REPO:-Huzhao-1991/s-ui-mo}"

#############################################
# Unattended mode
#
#   SUI_AUTO=1 bash install.sh
#
# Never prompts. On a fresh machine it generates a random admin account and
# random panel/subscription paths; on an existing one it keeps every existing
# setting. The panel's own "update" button runs this script with SUI_AUTO=1,
# so the second rule is load bearing: if a Web-triggered update rewrote the
# credentials, one click would lock the operator out of the panel.
#############################################
is_auto() {
    case "${SUI_AUTO}" in
    1 | true | TRUE | yes | Yes | on) return 0 ;;
    *) return 1 ;;
    esac
}

# gen_random_string [length] -- URL- and shell-safe random text.
#
# The obvious `head -c N /dev/urandom | base64` emits '/', '+' and a newline,
# all of which have to be escaped the moment the value goes into a URL or is
# echoed into a config. Filtering to the alphanumerics keeps it usable as a
# path segment, a password and a command-line argument without further care.
gen_random_string() {
    tr -dc 'a-zA-Z0-9' </dev/urandom | head -c "${1:-8}"
}

# is_port_listening <port> -- true when something already accepts connections
# on the loopback interface at that port.
is_port_listening() {
    (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null
}

# pick_port <preferred> -- the preferred port, or the next free one. A fresh
# install on a box already running something on 2095 used to end with the panel
# unable to bind and no explanation of why.
pick_port() {
    local port="${1:-2095}" tries=0
    while [[ "${tries}" -lt 50 ]]; do
        if ! is_port_listening "${port}"; then
            echo "${port}"
            return 0
        fi
        port=$((port + 1))
        tries=$((tries + 1))
    done
    echo "${port}"
}

#############################################
# Localization
#
# The installer speaks the six languages of the panel UI:
#   en (default), fa, ru, vi, zhcn, zhtw
# Pick one with the SUI_LANG environment variable, e.g.
#   SUI_LANG=fa bash <(curl -Ls .../install.sh)
# When SUI_LANG is unset the system $LANG is used as a hint.
#
# Messages are stored in flat variables (MSG_<lang>_<key>) and read through
# indirect expansion so the script also works on the older bash 3.2.
#############################################

detect_lang() {
    local l="${SUI_LANG:-}"
    if [[ -z "$l" ]]; then
        case "${LANG:-}" in
        fa*) l=fa ;;
        ru*) l=ru ;;
        vi*) l=vi ;;
        zh_TW* | zh_HK* | zh-TW*) l=zhtw ;;
        zh*) l=zhcn ;;
        *) l=en ;;
        esac
    fi
    case "$l" in
    fa | ru | vi | zhcn | zhtw | en) ;;
    zh-cn | zh_cn | zhCN) l=zhcn ;;
    zh-tw | zh_tw | zhTW) l=zhtw ;;
    *) l=en ;;
    esac
    echo "$l"
}
lang=$(detect_lang)

# d <lang> <key> <text> — define a localized message.
d() { eval "MSG_${1}_${2}=\$3"; }

d en root_err "Please run this script with root privilege"
d en os_fail "Failed to check the system OS, please contact the author!"
d en os_release "The OS release is:"
d en unsupported_arch "Unsupported CPU architecture!"
d en installing_base "Installing required packages..."
d en migrating "Migration..."
d en finished_modify "Install/update finished! For security it's recommended to modify panel settings"
d en ask_modify "Do you want to continue with the modification [y/n]? "
d en enter_port "Enter the panel port (leave blank for existing/default value):"
d en enter_path "Enter the panel path (leave blank for existing/default value):"
d en enter_subport "Enter the subscription port (leave blank for existing/default value):"
d en enter_subpath "Enter the subscription path (leave blank for existing/default value):"
d en initializing "Initializing, please wait..."
d en ask_admin "Do you want to change admin credentials [y/n]? "
d en set_user "Please set up your username: "
d en set_pass "Please set up your password: "
d en checksum_ok "Checksum verified."
d en checksum_fail "Checksum does NOT match. The download may be corrupt or tampered with. Aborting."
d en no_checksums "No SHA256SUMS published for this release; skipping checksum verification."
d en creds_empty "Username and password can not be empty."
d en creds_failed "Failed to set the admin credentials."
d en current_creds "Your current admin credentials:"
d en cancelled "cancel..."
d en fresh_random "this is a fresh installation, will generate random login info for security concerns:"
d en forgot_info "if you forgot your login info, you can type s-ui for configuration menu"
d en upgrade_keep "this is your upgrade, will keep old settings. If you forgot your login info, you can type s-ui for configuration menu"
d en stopping_singbox "Stopping sing-box service..."
d en bin_exists "directory exists yet! Please check the content and delete it manually after migration"
d en got_version "Got s-ui latest version: %s, beginning the installation..."
d en fetch_fail "Failed to fetch s-ui version, it maybe due to Github API restrictions, please try it later"
d en download_fail "Downloading s-ui failed, please be sure that your server can access Github"
d en begin_install "Beginning the install s-ui v%s"
d en download_ver_fail "download s-ui v%s failed, please check the version exists"
d en extract_fail "Extracting s-ui failed, the archive may be corrupt or the disk is full"
d en broken_bin "The installed s-ui binary does not run, the installation is incomplete"
d en install_finished "installation finished, it is up and running now..."
d en access_panel "You may access the Panel with following URL(s):"
d en executing "Executing..."

d fa root_err "لطفاً این اسکریپت را با دسترسی root اجرا کنید"
d fa os_fail "تشخیص سیستم عامل ناموفق بود، لطفاً با سازنده تماس بگیرید!"
d fa os_release "نسخهٔ سیستم عامل:"
d fa unsupported_arch "معماری پردازنده پشتیبانی نمی شود!"
d fa installing_base "در حال نصب پکیج های موردنیاز..."
d fa migrating "در حال مهاجرت پایگاه داده..."
d fa finished_modify "نصب/به روزرسانی به پایان رسید! برای امنیت بهتر است تنظیمات پنل را تغییر دهید"
d fa ask_modify "آیا می خواهید تنظیمات را تغییر دهید [y/n]؟ "
d fa enter_port "پورت پنل را وارد کنید (برای مقدار فعلی/پیش فرض خالی بگذارید):"
d fa enter_path "مسیر پنل را وارد کنید (برای مقدار فعلی/پیش فرض خالی بگذارید):"
d fa enter_subport "پورت اشتراک (subscription) را وارد کنید (برای مقدار فعلی/پیش فرض خالی بگذارید):"
d fa enter_subpath "مسیر اشتراک (subscription) را وارد کنید (برای مقدار فعلی/پیش فرض خالی بگذارید):"
d fa initializing "در حال آماده سازی، لطفاً صبر کنید..."
d fa ask_admin "آیا می خواهید نام کاربری و رمز ادمین را تغییر دهید [y/n]؟ "
d fa set_user "نام کاربری خود را وارد کنید: "
d fa set_pass "رمز عبور خود را وارد کنید: "
d fa checksum_ok "صحت فایل تایید شد."
d fa checksum_fail "مقدار checksum مطابقت ندارد. فایل دانلودشده خراب یا دستکاری شده است. عملیات متوقف شد."
d fa no_checksums "برای این نسخه فایل SHA256SUMS منتشر نشده؛ بررسی checksum انجام نشد."
d fa creds_empty "نام کاربری و رمز عبور نمی‌توانند خالی باشند."
d fa creds_failed "تنظیم نام کاربری و رمز ادمین ناموفق بود."
d fa current_creds "اطلاعات ورود ادمین فعلی شما:"
d fa cancelled "لغو شد..."
d fa fresh_random "این یک نصب تازه است؛ برای امنیت، اطلاعات ورود تصادفی ساخته می شود:"
d fa forgot_info "اگر اطلاعات ورود را فراموش کردید، دستور s-ui را برای منوی تنظیمات اجرا کنید"
d fa upgrade_keep "این یک ارتقا است و تنظیمات قبلی حفظ می شود. اگر اطلاعات ورود را فراموش کردید، دستور s-ui را برای منوی تنظیمات اجرا کنید"
d fa stopping_singbox "در حال متوقف کردن سرویس sing-box..."
d fa bin_exists "پوشه هنوز وجود دارد! لطفاً محتوای آن را بررسی و پس از مهاجرت به صورت دستی حذف کنید"
d fa got_version "آخرین نسخهٔ s-ui دریافت شد: %s، شروع نصب..."
d fa fetch_fail "دریافت نسخهٔ s-ui ناموفق بود؛ ممکن است به دلیل محدودیت های Github API باشد، بعداً دوباره تلاش کنید"
d fa download_fail "دانلود s-ui ناموفق بود؛ مطمئن شوید سرور شما به Github دسترسی دارد"
d fa begin_install "شروع نصب s-ui نسخهٔ v%s"
d fa download_ver_fail "دانلود s-ui نسخهٔ v%s ناموفق بود؛ لطفاً از وجود این نسخه مطمئن شوید"
d fa extract_fail "استخراج s-ui ناموفق بود؛ ممکن است فایل خراب باشد یا فضای دیسک پر باشد"
d fa broken_bin "باینری نصب‌شدهٔ s-ui اجرا نمی‌شود؛ نصب ناقص است"
d fa install_finished "نصب به پایان رسید و هم اکنون در حال اجراست..."
d fa access_panel "می توانید از طریق آدرس (های) زیر به پنل دسترسی داشته باشید:"
d fa executing "در حال اجرا..."

d ru root_err "Пожалуйста, запустите этот скрипт с правами root"
d ru os_fail "Не удалось определить ОС, пожалуйста, свяжитесь с автором!"
d ru os_release "Версия ОС:"
d ru unsupported_arch "Неподдерживаемая архитектура процессора!"
d ru installing_base "Установка необходимых пакетов..."
d ru migrating "Миграция..."
d ru finished_modify "Установка/обновление завершено! В целях безопасности рекомендуется изменить настройки панели"
d ru ask_modify "Хотите изменить настройки [y/n]? "
d ru enter_port "Введите порт панели (оставьте пустым для текущего/значения по умолчанию):"
d ru enter_path "Введите путь панели (оставьте пустым для текущего/значения по умолчанию):"
d ru enter_subport "Введите порт подписки (оставьте пустым для текущего/значения по умолчанию):"
d ru enter_subpath "Введите путь подписки (оставьте пустым для текущего/значения по умолчанию):"
d ru initializing "Инициализация, пожалуйста, подождите..."
d ru ask_admin "Хотите изменить учётные данные администратора [y/n]? "
d ru set_user "Задайте имя пользователя: "
d ru set_pass "Задайте пароль: "
d ru checksum_ok "Контрольная сумма проверена."
d ru checksum_fail "Контрольная сумма не совпадает. Файл повреждён или подменён. Прерывание."
d ru no_checksums "Для этого релиза нет SHA256SUMS; проверка контрольной суммы пропущена."
d ru creds_empty "Имя пользователя и пароль не могут быть пустыми."
d ru creds_failed "Не удалось задать учётные данные администратора."
d ru current_creds "Ваши текущие учётные данные администратора:"
d ru cancelled "отмена..."
d ru fresh_random "это новая установка, в целях безопасности будут сгенерированы случайные данные для входа:"
d ru forgot_info "если вы забыли данные для входа, введите s-ui для меню настроек"
d ru upgrade_keep "это обновление, старые настройки сохранятся. Если вы забыли данные для входа, введите s-ui для меню настроек"
d ru stopping_singbox "Остановка службы sing-box..."
d ru bin_exists "каталог всё ещё существует! Проверьте содержимое и удалите его вручную после миграции"
d ru got_version "Получена последняя версия s-ui: %s, начинается установка..."
d ru fetch_fail "Не удалось получить версию s-ui, возможно из-за ограничений Github API, попробуйте позже"
d ru download_fail "Не удалось загрузить s-ui, убедитесь, что ваш сервер имеет доступ к Github"
d ru begin_install "Начинается установка s-ui v%s"
d ru download_ver_fail "загрузка s-ui v%s не удалась, проверьте существование этой версии"
d ru extract_fail "Не удалось распаковать s-ui: архив повреждён или на диске нет места"
d ru broken_bin "Установленный файл s-ui не запускается, установка неполная"
d ru install_finished "установка завершена, панель запущена и работает..."
d ru access_panel "Вы можете получить доступ к панели по следующим URL:"
d ru executing "Выполнение..."

d vi root_err "Vui lòng chạy tập lệnh này với quyền root"
d vi os_fail "Không thể xác định hệ điều hành, vui lòng liên hệ tác giả!"
d vi os_release "Phiên bản hệ điều hành:"
d vi unsupported_arch "Kiến trúc CPU không được hỗ trợ!"
d vi installing_base "Đang cài đặt các gói cần thiết..."
d vi migrating "Đang di trú..."
d vi finished_modify "Cài đặt/cập nhật hoàn tất! Vì bảo mật, bạn nên chỉnh sửa cài đặt bảng điều khiển"
d vi ask_modify "Bạn có muốn tiếp tục chỉnh sửa [y/n]? "
d vi enter_port "Nhập cổng bảng điều khiển (để trống để giữ giá trị hiện tại/mặc định):"
d vi enter_path "Nhập đường dẫn bảng điều khiển (để trống để giữ giá trị hiện tại/mặc định):"
d vi enter_subport "Nhập cổng subscription (để trống để giữ giá trị hiện tại/mặc định):"
d vi enter_subpath "Nhập đường dẫn subscription (để trống để giữ giá trị hiện tại/mặc định):"
d vi initializing "Đang khởi tạo, vui lòng đợi..."
d vi ask_admin "Bạn có muốn thay đổi thông tin đăng nhập quản trị [y/n]? "
d vi set_user "Vui lòng đặt tên người dùng: "
d vi set_pass "Vui lòng đặt mật khẩu: "
d vi checksum_ok "Đã xác minh checksum."
d vi checksum_fail "Checksum KHÔNG khớp. Tệp tải về có thể bị hỏng hoặc bị can thiệp. Đang hủy."
d vi no_checksums "Bản phát hành này không có SHA256SUMS; bỏ qua xác minh checksum."
d vi creds_empty "Tên đăng nhập và mật khẩu không được để trống."
d vi creds_failed "Không thể đặt thông tin đăng nhập quản trị."
d vi current_creds "Thông tin đăng nhập quản trị hiện tại của bạn:"
d vi cancelled "đã hủy..."
d vi fresh_random "đây là cài đặt mới, sẽ tạo thông tin đăng nhập ngẫu nhiên vì lý do bảo mật:"
d vi forgot_info "nếu bạn quên thông tin đăng nhập, hãy gõ s-ui để mở menu cấu hình"
d vi upgrade_keep "đây là bản nâng cấp, cài đặt cũ sẽ được giữ lại. Nếu quên thông tin đăng nhập, hãy gõ s-ui để mở menu cấu hình"
d vi stopping_singbox "Đang dừng dịch vụ sing-box..."
d vi bin_exists "thư mục vẫn tồn tại! Vui lòng kiểm tra nội dung và xóa thủ công sau khi di trú"
d vi got_version "Đã lấy phiên bản s-ui mới nhất: %s, bắt đầu cài đặt..."
d vi fetch_fail "Không thể lấy phiên bản s-ui, có thể do giới hạn của Github API, vui lòng thử lại sau"
d vi download_fail "Tải s-ui thất bại, hãy chắc chắn máy chủ của bạn có thể truy cập Github"
d vi begin_install "Bắt đầu cài đặt s-ui v%s"
d vi download_ver_fail "tải s-ui v%s thất bại, vui lòng kiểm tra phiên bản có tồn tại không"
d vi extract_fail "Giải nén s-ui thất bại, tệp có thể bị hỏng hoặc đĩa đã đầy"
d vi broken_bin "Tệp s-ui đã cài đặt không chạy được, quá trình cài đặt chưa hoàn tất"
d vi install_finished "cài đặt hoàn tất, hiện đang chạy..."
d vi access_panel "Bạn có thể truy cập bảng điều khiển qua (các) URL sau:"
d vi executing "Đang thực thi..."

d zhcn root_err "请使用 root 权限运行此脚本"
d zhcn os_fail "无法检测系统操作系统，请联系作者！"
d zhcn os_release "操作系统版本："
d zhcn unsupported_arch "不支持的 CPU 架构！"
d zhcn installing_base "正在安装所需软件包..."
d zhcn migrating "正在迁移..."
d zhcn finished_modify "安装/更新完成！为了安全，建议修改面板设置"
d zhcn ask_modify "是否继续修改设置 [y/n]？ "
d zhcn enter_port "请输入面板端口（留空则使用现有/默认值）："
d zhcn enter_path "请输入面板路径（留空则使用现有/默认值）："
d zhcn enter_subport "请输入订阅端口（留空则使用现有/默认值）："
d zhcn enter_subpath "请输入订阅路径（留空则使用现有/默认值）："
d zhcn initializing "正在初始化，请稍候..."
d zhcn ask_admin "是否修改管理员账号密码 [y/n]？ "
d zhcn set_user "请设置您的用户名： "
d zhcn set_pass "请设置您的密码： "
d zhcn checksum_ok "校验和已验证。"
d zhcn checksum_fail "校验和不匹配，下载文件可能已损坏或被篡改。已中止。"
d zhcn no_checksums "此版本未发布 SHA256SUMS，已跳过校验和验证。"
d zhcn creds_empty "用户名和密码不能为空。"
d zhcn creds_failed "设置管理员账号密码失败。"
d zhcn current_creds "您当前的管理员登录信息："
d zhcn cancelled "已取消..."
d zhcn fresh_random "这是全新安装，为了安全将生成随机登录信息："
d zhcn forgot_info "如果忘记登录信息，可以输入 s-ui 打开配置菜单"
d zhcn upgrade_keep "这是升级，将保留旧设置。如果忘记登录信息，可以输入 s-ui 打开配置菜单"
d zhcn stopping_singbox "正在停止 sing-box 服务..."
d zhcn bin_exists "目录仍然存在！请检查内容并在迁移后手动删除"
d zhcn got_version "已获取 s-ui 最新版本：%s，开始安装..."
d zhcn fetch_fail "获取 s-ui 版本失败，可能是由于 Github API 限制，请稍后再试"
d zhcn download_fail "下载 s-ui 失败，请确保您的服务器可以访问 Github"
d zhcn begin_install "开始安装 s-ui v%s"
d zhcn download_ver_fail "下载 s-ui v%s 失败，请检查该版本是否存在"
d zhcn extract_fail "解压 s-ui 失败，压缩包可能已损坏或磁盘空间不足"
d zhcn broken_bin "已安装的 s-ui 程序无法运行，安装不完整"
d zhcn install_finished "安装完成，现已运行..."
d zhcn access_panel "您可以通过以下 URL 访问面板："
d zhcn executing "正在执行..."

d zhtw root_err "請使用 root 權限執行此腳本"
d zhtw os_fail "無法偵測系統作業系統，請聯絡作者！"
d zhtw os_release "作業系統版本："
d zhtw unsupported_arch "不支援的 CPU 架構！"
d zhtw installing_base "正在安裝所需套件..."
d zhtw migrating "正在遷移..."
d zhtw finished_modify "安裝/更新完成！為了安全，建議修改面板設定"
d zhtw ask_modify "是否繼續修改設定 [y/n]？ "
d zhtw enter_port "請輸入面板連接埠（留空則使用現有/預設值）："
d zhtw enter_path "請輸入面板路徑（留空則使用現有/預設值）："
d zhtw enter_subport "請輸入訂閱連接埠（留空則使用現有/預設值）："
d zhtw enter_subpath "請輸入訂閱路徑（留空則使用現有/預設值）："
d zhtw initializing "正在初始化，請稍候..."
d zhtw ask_admin "是否修改管理員帳號密碼 [y/n]？ "
d zhtw set_user "請設定您的使用者名稱： "
d zhtw set_pass "請設定您的密碼： "
d zhtw checksum_ok "校驗和已驗證。"
d zhtw checksum_fail "校驗和不相符，下載檔案可能已損毀或被竄改。已中止。"
d zhtw no_checksums "此版本未發布 SHA256SUMS，已略過校驗和驗證。"
d zhtw creds_empty "使用者名稱與密碼不能為空。"
d zhtw creds_failed "設定管理員帳號密碼失敗。"
d zhtw current_creds "您目前的管理員登入資訊："
d zhtw cancelled "已取消..."
d zhtw fresh_random "這是全新安裝，為了安全將產生隨機登入資訊："
d zhtw forgot_info "如果忘記登入資訊，可以輸入 s-ui 開啟設定選單"
d zhtw upgrade_keep "這是升級，將保留舊設定。如果忘記登入資訊，可以輸入 s-ui 開啟設定選單"
d zhtw stopping_singbox "正在停止 sing-box 服務..."
d zhtw bin_exists "目錄仍然存在！請檢查內容並在遷移後手動刪除"
d zhtw got_version "已取得 s-ui 最新版本：%s，開始安裝..."
d zhtw fetch_fail "取得 s-ui 版本失敗，可能是由於 Github API 限制，請稍後再試"
d zhtw download_fail "下載 s-ui 失敗，請確保您的伺服器可以存取 Github"
d zhtw begin_install "開始安裝 s-ui v%s"
d zhtw download_ver_fail "下載 s-ui v%s 失敗，請檢查該版本是否存在"
d zhtw extract_fail "解壓 s-ui 失敗，壓縮檔可能已損毀或磁碟空間不足"
d zhtw broken_bin "已安裝的 s-ui 程式無法執行，安裝不完整"
d zhtw install_finished "安裝完成，現已執行..."
d zhtw access_panel "您可以透過以下 URL 存取面板："
d zhtw executing "正在執行..."

#############################################
# Messages for the features added on top of upstream: unattended install and
# purge. `t` already falls back to English, so the other four languages keep
# working without a translation.
#############################################
d en auto_mode "Unattended mode: nothing will be asked."
d en auto_summary "Generated settings -- save these now, they are shown only once"
d en panel_port "Panel port"
d en panel_path "Panel path"
d en sub_port "Subscription port"
d en sub_path "Subscription path"
d en username "Username"
d en password "Password"
d en purging "Removing s-ui..."
d en purge_done "s-ui removed. Nothing of it is left on this machine."
d en uninstall_warn "This removes the s-ui program and its service."
d en uninstall_keep_db "s-ui removed. The database under /etc/s-ui was kept; run 'install.sh purge' to delete that too."

d zhcn auto_mode "自动模式：全程不再询问。"
d zhcn auto_summary "已生成以下设置 —— 请立即保存，只显示这一次"
d zhcn panel_port "面板端口"
d zhcn panel_path "面板路径"
d zhcn sub_port "订阅端口"
d zhcn sub_path "订阅路径"
d zhcn username "账号"
d zhcn password "密码"
d zhcn purging "正在卸载 s-ui..."
d zhcn purge_done "s-ui 已彻底清除，本机不留任何残留。"
d zhcn uninstall_warn "将删除 s-ui 程序与其服务。"
d zhcn uninstall_keep_db "s-ui 已卸载，/etc/s-ui 下的数据库保留；如需一并删除请执行 install.sh purge。"

# t <key> — return the localized message, falling back to English.
t() {
    local var="MSG_${lang}_$1"
    local val="${!var}"
    if [[ -z "$val" ]]; then
        var="MSG_en_$1"
        val="${!var}"
    fi
    printf '%s' "$val"
}

# check root
[[ $EUID -ne 0 ]] && echo -e "${red}$(t root_err)${plain}\n" && exit 1

# Check OS and set release variable
if [[ -f /etc/os-release ]]; then
    source /etc/os-release
    release=$ID
elif [[ -f /usr/lib/os-release ]]; then
    source /usr/lib/os-release
    release=$ID
else
    echo -e "${red}$(t os_fail)${plain}" >&2
    exit 1
fi
echo -e "$(t os_release) $release"

# Detect the init system (systemd vs OpenRC used by Alpine)
if [[ "$release" == "alpine" ]]; then
    init_system="openrc"
elif command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
    init_system="systemd"
elif command -v rc-service >/dev/null 2>&1; then
    init_system="openrc"
else
    init_system="systemd"
fi

arch() {
    case "$(uname -m)" in
    x86_64 | x64 | amd64) echo 'amd64' ;;
    i*86 | x86) echo '386' ;;
    armv8* | armv8 | arm64 | aarch64) echo 'arm64' ;;
    armv7* | armv7 | arm) echo 'armv7' ;;
    armv6* | armv6) echo 'armv6' ;;
    armv5* | armv5) echo 'armv5' ;;
    s390x) echo 's390x' ;;
    *) echo -e "${green}$(t unsupported_arch)${plain}" && rm -f install.sh && exit 1 ;;
    esac
}

echo "arch: $(arch)"

install_base() {
    echo -e "${yellow}$(t installing_base)${plain}"
    case "${release}" in
    centos | almalinux | rocky | oracle)
        yum -y update && yum install -y -q wget curl tar
        ;;
    fedora)
        dnf -y update && dnf install -y -q wget curl tar
        ;;
    arch | manjaro | parch)
        pacman -Syu && pacman -Syu --noconfirm wget curl tar
        ;;
    opensuse-tumbleweed)
        zypper refresh && zypper -q install -y wget curl tar
        ;;
    alpine)
        # Alpine uses apk and OpenRC; bash is needed for the s-ui menu script.
        apk update && apk add --no-cache wget curl tar bash openrc
        ;;
    *)
        apt-get update && apt-get install -y -q wget curl tar
        ;;
    esac
}

# Write an OpenRC service definition (Alpine and other OpenRC systems).
install_openrc_service() {
    cat >/etc/init.d/s-ui <<'EOF'
#!/sbin/openrc-run

description="s-ui Service"
command="/usr/local/s-ui/sui"
command_background=true
directory="/usr/local/s-ui"
pidfile="/run/s-ui.pid"
output_log="/var/log/s-ui.log"
error_log="/var/log/s-ui.log"
respawn_delay=10
supervisor=supervise-daemon

depend() {
    need localmount
    use net dns logger firewall
    after net firewall
}
EOF
    chmod +x /etc/init.d/s-ui
}

config_after_install() {
    echo -e "${yellow}$(t migrating)${plain}"
    /usr/local/s-ui/sui migrate

    if is_auto; then
        auto_config
        return
    fi

    echo -e "${yellow}$(t finished_modify)${plain}"
    read -r -p "$(t ask_modify)" config_confirm
    if [[ "${config_confirm}" == "y" || "${config_confirm}" == "Y" ]]; then
        echo -e "${yellow}$(t enter_port)${plain}"
        read -r config_port
        echo -e "${yellow}$(t enter_path)${plain}"
        read -r config_path

        # Sub configuration
        echo -e "${yellow}$(t enter_subport)${plain}"
        read -r config_subPort
        echo -e "${yellow}$(t enter_subpath)${plain}"
        read -r config_subPath

        # Set configs
        echo -e "${yellow}$(t initializing)${plain}"
        params=()
        [ -z "$config_port" ] || params+=(-port "$config_port")
        [ -z "$config_path" ] || params+=(-path "$config_path")
        [ -z "$config_subPort" ] || params+=(-subPort "$config_subPort")
        [ -z "$config_subPath" ] || params+=(-subPath "$config_subPath")
        /usr/local/s-ui/sui setting "${params[@]}"

        read -r -p "$(t ask_admin)" admin_confirm
        if [[ "${admin_confirm}" == "y" || "${admin_confirm}" == "Y" ]]; then
            # First admin credentials. -s so the password does not end up on
            # screen or in the scrollback of a shared terminal.
            read -r -p "$(t set_user)" config_account
            read -r -s -p "$(t set_pass)" config_password
            echo

            # Both have to be non-empty. Passing an empty -password used to
            # store the hash of "", which authenticates anyone who submits an
            # empty password.
            if [[ -z "$config_account" || -z "$config_password" ]]; then
                echo -e "${red}$(t creds_empty)${plain}"
                exit 1
            fi

            # Set credentials
            echo -e "${yellow}$(t initializing)${plain}"
            if ! /usr/local/s-ui/sui admin -username "${config_account}" -password "${config_password}"; then
                echo -e "${red}$(t creds_failed)${plain}"
                exit 1
            fi
        else
            echo -e "${yellow}$(t current_creds)${plain}"
            /usr/local/s-ui/sui admin -show
        fi
    else
        echo -e "${red}$(t cancelled)${plain}"
        if [[ ! -f "/usr/local/s-ui/db/s-ui.db" ]]; then
            local usernameTemp=$(head -c 6 /dev/urandom | base64)
            local passwordTemp=$(head -c 6 /dev/urandom | base64)
            echo -e "$(t fresh_random)"
            echo -e "###############################################"
            echo -e "${green}username:${usernameTemp}${plain}"
            echo -e "${green}password:${passwordTemp}${plain}"
            echo -e "###############################################"
            echo -e "${red}$(t forgot_info)${plain}"
            if ! /usr/local/s-ui/sui admin -username "${usernameTemp}" -password "${passwordTemp}"; then
                echo -e "${red}$(t creds_failed)${plain}"
                exit 1
            fi
        else
            echo -e "${red}$(t upgrade_keep)${plain}"
        fi
    fi
}

# auto_config writes settings for an unattended install.
#
# On an existing installation it deliberately does nothing but report: the
# database is the operator's, and this path is also the one the panel's Web
# update button drives. Generating an account here would hand the panel a new
# password the operator never sees.
auto_config() {
    if [[ -f "/usr/local/s-ui/db/s-ui.db" ]]; then
        echo -e "${green}$(t upgrade_keep)${plain}"
        /usr/local/s-ui/sui admin -show
        return 0
    fi

    local p_port p_path p_subport p_subpath p_user p_pass
    p_port="${SUI_PORT:-$(pick_port 2095)}"
    p_subport="${SUI_SUB_PORT:-$(pick_port 2096)}"
    p_path="${SUI_PATH:-/$(gen_random_string 8)/}"
    p_subpath="${SUI_SUB_PATH:-/$(gen_random_string 8)/}"
    p_user="${SUI_USER:-ad$(gen_random_string 6)}"
    p_pass="${SUI_PASSWORD:-$(gen_random_string 16)}"

    echo -e "${yellow}$(t initializing)${plain}"
    if ! /usr/local/s-ui/sui setting -port "${p_port}" -path "${p_path}" \
        -subPort "${p_subport}" -subPath "${p_subpath}"; then
        echo -e "${red}$(t creds_failed)${plain}"
        exit 1
    fi
    if ! /usr/local/s-ui/sui admin -username "${p_user}" -password "${p_pass}"; then
        echo -e "${red}$(t creds_failed)${plain}"
        exit 1
    fi

    echo
    echo -e "${green}###############################################${plain}"
    echo -e "${green} $(t auto_summary)${plain}"
    echo -e "${green}###############################################${plain}"
    echo -e "${green} $(t panel_port) : ${plain}${p_port}"
    echo -e "${green} $(t panel_path) : ${plain}${p_path}"
    echo -e "${green} $(t sub_port)   : ${plain}${p_subport}"
    echo -e "${green} $(t sub_path)   : ${plain}${p_subpath}"
    echo -e "${green} $(t username)   : ${plain}${p_user}"
    echo -e "${green} $(t password)   : ${plain}${p_pass}"
    echo -e "${green}###############################################${plain}"
    echo
}

stop_service() {
    if [[ "${init_system}" == "systemd" ]] && command -v systemctl >/dev/null 2>&1; then
        systemctl stop s-ui 2>/dev/null
        systemctl disable s-ui 2>/dev/null
        rm -f /etc/systemd/system/s-ui.service
        systemctl daemon-reload 2>/dev/null
        systemctl reset-failed 2>/dev/null
    elif [[ "${init_system}" == "openrc" ]] && command -v rc-service >/dev/null 2>&1; then
        rc-service s-ui stop 2>/dev/null
        rc-update del s-ui default 2>/dev/null
        rm -f /etc/init.d/s-ui
    fi
}

# uninstall_s-ui removes the program and the service, and leaves the database
# alone. Nothing is checked first: a half-finished install leaves the panel in a
# state where "is it installed" is false, and gating removal on that test makes
# the leftovers impossible to clean and a reinstall impossible to start.
uninstall_s-ui() {
    echo -e "${yellow}$(t uninstall_warn)${plain}"
    stop_service
    rm -rf /usr/local/s-ui
    rm -f /usr/bin/s-ui
    echo -e "${green}$(t uninstall_keep_db)${plain}"
}

# purge_s-ui removes everything, including /etc/s-ui. It depends on nothing but
# being root, so it works on a machine where /usr/bin/s-ui is already gone --
# which is exactly the machine that needs it.
purge_s-ui() {
    echo -e "${yellow}$(t purging)${plain}"
    stop_service
    rm -rf /usr/local/s-ui
    rm -rf /etc/s-ui
    rm -f /usr/bin/s-ui
    echo -e "${green}$(t purge_done)${plain}"
}

prepare_services() {
    if [[ "${init_system}" == "systemd" ]]; then
        if [[ -f "/etc/systemd/system/sing-box.service" ]]; then
            echo -e "${yellow}$(t stopping_singbox)${plain}"
            systemctl stop sing-box
            rm -f /usr/local/s-ui/bin/sing-box /usr/local/s-ui/bin/runSingbox.sh /usr/local/s-ui/bin/signal
        fi
    fi
    if [[ -e "/usr/local/s-ui/bin" ]]; then
        echo -e "###############################################################"
        echo -e "${green}/usr/local/s-ui/bin${red} $(t bin_exists)${plain}"
        echo -e "###############################################################"
    fi
    if [[ "${init_system}" == "systemd" ]]; then
        systemctl daemon-reload
    fi
}

# verify_checksum checks the downloaded archive against the SHA256SUMS file the
# release publishes. A release without one (anything built before this was
# added) is installed with a warning rather than refused, so an older version
# can still be rolled back to.
verify_checksum() {
    local archive="$1" sums="$2" name expected actual
    name=$(basename "$archive")

    if [[ ! -s "$sums" ]] || ! command -v sha256sum >/dev/null 2>&1; then
        echo -e "${yellow}$(t no_checksums)${plain}"
        return 0
    fi

    # Matched by filename, and the leading * that sha256sum writes for a binary
    # entry is accepted. Comparing the hashes directly rather than piping into
    # `sha256sum -c` keeps this independent of the working directory, which the
    # paths in a SHA256SUMS file are relative to.
    expected=$(awk -v f="$name" '$2 == f || $2 == "*" f { print $1; exit }' "$sums")
    if [[ -z "$expected" ]]; then
        echo -e "${yellow}$(t no_checksums)${plain}"
        return 0
    fi

    actual=$(sha256sum "$archive" | awk '{ print $1 }')
    if [[ "$expected" != "$actual" ]]; then
        echo -e "${red}$(t checksum_fail)${plain}"
        return 1
    fi
    echo -e "${green}$(t checksum_ok)${plain}"
}

install_s-ui() {
    # A private directory, not /tmp itself. The old path was predictable, so on
    # a shared host another user could pre-create the archive or the extracted
    # tree and have root install it.
    workdir=$(mktemp -d "${TMPDIR:-/tmp}/s-ui-install.XXXXXXXX") || exit 1
    trap 'rm -rf "$workdir"' EXIT
    cd "$workdir" || exit 1

    local archive="$workdir/s-ui-linux-$(arch).tar.gz"
    local sums="$workdir/SHA256SUMS"

    if [ $# == 0 ]; then
        last_version=$(curl -Ls "https://api.github.com/repos/${SUI_REPO}/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
        if [[ ! -n "$last_version" ]]; then
            echo -e "${red}$(t fetch_fail)${plain}"
            exit 1
        fi
        printf "${green}$(t got_version)${plain}\n" "${last_version}"
    else
        last_version=$1
        printf "$(t begin_install)\n" "$1"
    fi

    # No --no-check-certificate. It was on every download here, which turns the
    # whole install into an unauthenticated fetch: anyone able to intercept it
    # chooses the binary that then runs as root.
    local base="https://github.com/${SUI_REPO}/releases/download/${last_version}"
    if ! wget -q --show-progress -O "$archive" "${base}/s-ui-linux-$(arch).tar.gz"; then
        if [ $# == 0 ]; then
            echo -e "${red}$(t download_fail)${plain}"
        else
            printf "${red}$(t download_ver_fail)${plain}\n" "$1"
        fi
        exit 1
    fi
    wget -q -O "$sums" "${base}/SHA256SUMS" 2>/dev/null || : # older releases have none
    verify_checksum "$archive" "$sums" || exit 1

    if [[ -e /usr/local/s-ui/ ]]; then
        if [[ "${init_system}" == "systemd" ]]; then
            systemctl stop s-ui
        elif [[ "${init_system}" == "openrc" ]]; then
            rc-service s-ui stop 2>/dev/null
        fi
    fi

    if ! tar zxf "$archive" -C "$workdir"; then
        echo -e "${red}$(t extract_fail)${plain}"
        df -h "$workdir" /usr/local 2>/dev/null
        exit 1
    fi
    rm -f "$archive"

    chmod +x s-ui/sui s-ui/s-ui.sh
    cp s-ui/s-ui.sh /usr/bin/s-ui
    if ! cp -rf s-ui /usr/local/; then
        echo -e "${red}$(t extract_fail)${plain}"
        df -h /usr/local 2>/dev/null
        rm -rf s-ui
        exit 1
    fi
    if ! /usr/local/s-ui/sui -v >/dev/null 2>&1; then
        echo -e "${red}$(t broken_bin)${plain}"
        df -h /usr/local 2>/dev/null
        rm -rf s-ui
        exit 1
    fi
    if [[ "${init_system}" == "systemd" ]]; then
        cp -f s-ui/*.service /etc/systemd/system/
    fi
    rm -rf s-ui

    config_after_install
    prepare_services

    if [[ "${init_system}" == "openrc" ]]; then
        install_openrc_service
        rc-update add s-ui default
        rc-service s-ui restart
    else
        systemctl enable s-ui --now
    fi

    # No "v" here: the release tag already carries one (v1.6.3-mo1), and the
    # upstream line hardcoded an extra literal "v" in front of it, so every
    # install announced "s-ui vv1.6.3-mo1".
    printf "${green}s-ui ${last_version}${plain} $(t install_finished)\n"
    echo -e "$(t access_panel)${green}"
    /usr/local/s-ui/sui uri
    echo -e "${plain}"
    echo -e ""
    s-ui help
}

# Subcommands, handled before anything is installed or downloaded.
#   install.sh purge      -- delete s-ui and its data, nothing needs to exist
#   install.sh uninstall  -- delete the program and service, keep the database
case "${1:-}" in
purge)
    purge_s-ui
    exit 0
    ;;
uninstall)
    uninstall_s-ui
    exit 0
    ;;
esac

echo -e "${green}$(t executing)${plain}"
if is_auto; then
    echo -e "${green}$(t auto_mode)${plain}"
fi
install_base
install_s-ui $1
