#!/usr/bin/env bash

[[ -z "$DISTRO" || -z "$LOG_FILE" ]] && exit 1

source "./utils/formatter.sh"
source "./utils/prompter.sh"
source "./utils/packages.sh"

declare -r CPU_VENDOR=$(case "$VENDOR_ID" in
  *AuthenticAMD*) echo "amd" ;;
  *GenuineIntel*) echo "intel" ;;
  *) fmtr::error "Unknown CPU vendor."; exit 1 ;;
esac)

readonly SRC_DIR="src"
readonly QEMU_VERSION="9.2.0"
readonly QEMU_DIR="qemu-${QEMU_VERSION}"
readonly QEMU_ARCHIVE="${QEMU_DIR}.tar.xz"
readonly QEMU_SIG="${QEMU_ARCHIVE}.sig"
readonly QEMU_URL="https://download.qemu.org/${QEMU_ARCHIVE}"
readonly QEMU_SIG_URL="${QEMU_URL}.sig"
readonly PATCH_DIR="../../patches/QEMU"
readonly QEMU_PATCH="${CPU_VENDOR}-${QEMU_DIR}.patch"
readonly QEMU_LIBNFS_PATCH="${QEMU_DIR}-libnfs6.patch"
readonly GPG_KEY="CEACC9E15534EBABB82D3FA03353C9CEF108B584"

REQUIRED_PKGS_Arch=(
  base-devel dmidecode glib2 libusb ninja
  python-packaging python-sphinx python-sphinx_rtd_theme gnupg

  # Spice Dependency
  spice
)
REQUIRED_PKGS_Debian=(
  build-essential libfdt-dev libglib2.0-dev libpixman-1-dev
  libusb-1.0-0-dev ninja-build python3-venv zlib1g-dev gnupg

  # Spice Dependency
  spice
)
REQUIRED_PKGS_openSUSE=(
  bzip2 gcc-c++ gpg2 glib2-devel make qemu  
  libpixman-1-0-devel libusb-1_0-devel patch
  python3-Sphinx ninja

  # Spice Dependency
  spice
)
REQUIRED_PKGS_Fedora=(
  bzip2 glib2-devel libfdt-devel libusb1-devel
  ninja-build pixman-devel python3 zlib-devel gnupg2

  # Spice Dependency
  spice
)

acquire_qemu_source() {
  mkdir -p "$SRC_DIR" && cd "$SRC_DIR"

  if [ -d "$QEMU_DIR" ]; then
    fmtr::warn "Directory $QEMU_DIR already exists."
    if ! prmt::yes_or_no "$(fmtr::ask 'Delete and re-download the QEMU source?')"; then
      fmtr::info "Keeping existing directory. Skipping re-download."
      cd "$QEMU_DIR" || { fmtr::fatal "Failed to change to QEMU directory: $QEMU_DIR"; exit 1; }
      return
    fi
    sudo rm -rf "$QEMU_DIR" || { fmtr::fatal "Failed to remove existing directory: $QEMU_DIR"; exit 1; }
    fmtr::info "Old directory deleted. Re-downloading..."
  fi

  fmtr::info "Downloading QEMU source archive and signature..."
  curl -sSO "$QEMU_URL" || { fmtr::fatal "Failed to download QEMU source archive."; exit 1; }
  curl -sSO "$QEMU_SIG_URL" || { fmtr::fatal "Failed to download QEMU signature file."; exit 1; }

  fmtr::log "Verifying source authenticity..."
  if ! gpg --keyserver keys.openpgp.org --recv-keys "$GPG_KEY" &>> "$LOG_FILE"; then
    fmtr::fatal "Failed to import QEMU signing key"
    exit 1
  fi

  if ! gpg --verify "$QEMU_SIG" "$QEMU_ARCHIVE" &>> "$LOG_FILE"; then
    fmtr::fatal "Signature verification FAILED! Archive may be compromised."
    exit 1
  fi
  fmtr::log "Signature verification successful"

  fmtr::info "Extracting QEMU source archive..."
  tar xJf "$QEMU_ARCHIVE" || { fmtr::fatal "Failed to extract QEMU archive."; exit 1; }

  cd "$QEMU_DIR" || { fmtr::fatal "Failed to change to QEMU directory: $QEMU_DIR"; exit 1; }
  fmtr::info "QEMU source successfully acquired and extracted."
}

patch_qemu() {
  if [ ! -f "${PATCH_DIR}/${QEMU_PATCH}" ]; then
    fmtr::error "Patch file ${PATCH_DIR}/${QEMU_PATCH} not found!"
    fmtr::fatal "Cannot proceed without the patch file. Exiting."
    exit 1
  fi

  if [ ! -f "${PATCH_DIR}/${QEMU_LIBNFS_PATCH}" ]; then
    fmtr::error "Patch file ${PATCH_DIR}/${QEMU_LIBNFS_PATCH} not found!"
    fmtr::fatal "Cannot proceed without the libnfs patch file. Exiting."
    exit 1
  fi

  fmtr::info "Applying patches to QEMU..."

  patch -fsp1 < "${PATCH_DIR}/${QEMU_LIBNFS_PATCH}" &>> "$LOG_FILE" || {
    fmtr::error "Failed to apply patch ${QEMU_LIBNFS_PATCH}!"
    fmtr::fatal "libNFS patch application failed. Please check the log for errors."
    exit 1
  }

  patch -fsp1 < "${PATCH_DIR}/${QEMU_PATCH}" &>> "$LOG_FILE" || {
    fmtr::error "Failed to apply patch ${QEMU_PATCH}!"
    fmtr::fatal "Patch application failed. Please check the log for errors."
    exit 1
  }

  fmtr::log "Spoofing all model & serial numbers\n"
  echo ""

  spoof_serial_numbers
  spoof_drive_serial_number
  spoof_acpi_table_strings
  spoof_cpuid_manufacturer
}

spoof_serial_numbers() {
  get_random_serial() { head /dev/urandom | tr -dc 'A-Z0-9' | head -c "$1"; }

  print_modified() {
    local file="$1"
    local value="$2"
    local file_name="$(basename "$file")"
    local file_log="$(fmtr::format_text '  ' "Modified:" " '$file_name'" "$TEXT_GREEN")"
    local value_log="$(fmtr::format_text ' with new value(s): ' "$value" '' "$TEXT_GREEN")"
    echo "${file_log}${value_log}" | tee -a "$LOG_FILE"
  }

  # Define the patterns to look for
  local patterns=("STRING_SERIALNUMBER" "STR_SERIALNUMBER" "STR_SERIAL_MOUSE" "STR_SERIAL_TABLET" "STR_SERIAL_KEYBOARD" "STR_SERIAL_COMPAT")

  # Create a regex pattern by joining the patterns with |
  local regex_pattern=$(IFS="|"; echo "${patterns[*]}")

  # Find and process files containing the specified patterns
  readarray -t files < <(find "$(pwd)/hw/usb" -type f -exec grep -lE "\[(${regex_pattern})\]" {} +)

  for file in "${files[@]}"; do
    local new_content=()
    while IFS= read -r line; do
      if [[ $line =~ \[(${regex_pattern})\] ]]; then
        local new_serial="$(get_random_serial 10)"
        line=$(echo "$line" | sed -E "s/(\[(${regex_pattern})\] *= *\")[^\"]*/\1${new_serial}/")
        print_modified "$file" "$new_serial"
      fi
      new_content+=("$line")
    done < "$file"

    # Write the modified content back to the file
    printf "%s\n" "${new_content[@]}" > "$file"
  done
}

spoof_drive_serial_number() {
  local core_file="$(pwd)/hw/ide/core.c"
  local new_serial="$(get_random_serial 15)"

  local ide_cd_models=(
    "HL-DT-ST BD-RE WH16NS60" "HL-DT-ST DVDRAM GH24NSC0"
    "HL-DT-ST BD-RE BH16NS40" "HL-DT-ST DVD+-RW GT80N"
    "HL-DT-ST DVD-RAM GH22NS30" "HL-DT-ST DVD+RW GCA-4040N"
    "Pioneer BDR-XD07B" "Pioneer DVR-221LBK" "Pioneer BDR-209DBK"
    "Pioneer DVR-S21WBK" "Pioneer BDR-XD05B" "ASUS BW-16D1HT"
    "ASUS DRW-24B1ST" "ASUS SDRW-08D2S-U" "ASUS BC-12D2HT"
    "ASUS SBW-06D2X-U" "Samsung SH-224FB" "Samsung SE-506BB"
    "Samsung SH-B123L" "Samsung SE-208GB" "Samsung SN-208DB"
    "Sony NEC Optiarc AD-5280S" "Sony DRU-870S" "Sony BWU-500S"
    "Sony NEC Optiarc AD-7261S" "Sony AD-7200S" "Lite-On iHAS124-14"
    "Lite-On iHBS112-04" "Lite-On eTAU108" "Lite-On iHAS324-17"
    "Lite-On eBAU108" "HP DVD1260i" "HP DVD640"
    "HP BD-RE BH30L" "HP DVD Writer 300n" "HP DVD Writer 1265i"
  )

  local ide_cfata_models=(
    "SanDisk Ultra microSDXC UHS-I" "SanDisk Extreme microSDXC UHS-I"
    "SanDisk High Endurance microSDXC" "SanDisk Industrial microSD"
    "SanDisk Mobile Ultra microSDHC" "Samsung EVO Select microSDXC"
    "Samsung PRO Endurance microSDHC" "Samsung PRO Plus microSDXC"
    "Samsung EVO Plus microSDXC" "Samsung PRO Ultimate microSDHC"
    "Kingston Canvas React Plus microSD" "Kingston Canvas Go! Plus microSD"
    "Kingston Canvas Select Plus microSD" "Kingston Industrial microSD"
    "Kingston Endurance microSD" "Lexar Professional 1066x microSDXC"
    "Lexar High-Performance 633x microSDHC" "Lexar PLAY microSDXC"
    "Lexar Endurance microSD" "Lexar Professional 1000x microSDHC"
    "PNY Elite-X microSD" "PNY PRO Elite microSD"
    "PNY High Performance microSD" "PNY Turbo Performance microSD"
    "PNY Premier-X microSD" "Transcend High Endurance microSDXC"
    "Transcend Ultimate microSDXC" "Transcend Industrial Temp microSD"
    "Transcend Premium microSDHC" "Transcend Superior microSD"
    "ADATA Premier Pro microSDXC" "ADATA XPG microSDXC"
    "ADATA High Endurance microSDXC" "ADATA Premier microSDHC"
    "ADATA Industrial microSD" "Toshiba Exceria Pro microSDXC"
    "Toshiba Exceria microSDHC" "Toshiba M203 microSD"
    "Toshiba N203 microSD" "Toshiba High Endurance microSD"
  )

  local default_models=(
    "Samsung SSD 970 EVO 1TB" "Samsung SSD 860 QVO 1TB"
    "Samsung SSD 850 PRO 1TB" "Samsung SSD T7 Touch 1TB"
    "Samsung SSD 840 EVO 1TB" "WD Blue SN570 NVMe SSD 1TB"
    "WD Black SN850 NVMe SSD 1TB" "WD Green 1TB SSD"
    "WD My Passport SSD 1TB" "WD Blue 3D NAND 1TB SSD"
    "Seagate BarraCuda SSD 1TB" "Seagate FireCuda 520 SSD 1TB"
    "Seagate One Touch SSD 1TB" "Seagate IronWolf 110 SSD 1TB"
    "Seagate Fast SSD 1TB" "Crucial MX500 1TB 3D NAND SSD"
    "Crucial P5 Plus NVMe SSD 1TB" "Crucial BX500 1TB 3D NAND SSD"
    "Crucial X8 Portable SSD 1TB" "Crucial P3 1TB PCIe 3.0 3D NAND NVMe SSD"
    "Kingston A2000 NVMe SSD 1TB" "Kingston KC2500 NVMe SSD 1TB"
    "Kingston A400 SSD 1TB" "Kingston HyperX Savage SSD 1TB"
    "Kingston DataTraveler Vault Privacy 3.0 1TB" "SanDisk Ultra 3D NAND SSD 1TB"
    "SanDisk Extreme Portable SSD V2 1TB" "SanDisk SSD PLUS 1TB"
    "SanDisk Ultra 3D 1TB NAND SSD" "SanDisk Extreme Pro 1TB NVMe SSD"
  )

  get_random_element() {
    local array=("$@")
    echo "${array[RANDOM % ${#array[@]}]}"
  }

  local new_ide_cd_model=$(get_random_element "${ide_cd_models[@]}")
  local new_ide_cfata_model=$(get_random_element "${ide_cfata_models[@]}")
  local new_default_model=$(get_random_element "${default_models[@]}")

  sed -i "$core_file" -Ee "s/\"[^\"]*%05d\", s->drive_serial\);/\"${new_serial}%05d\", s->drive_serial\);/"
  sed -i "$core_file" -Ee "s/\"HL-DT-ST BD-RE WH16NS60\"/\"${new_ide_cd_model}\"/"
  sed -i "$core_file" -Ee "s/\"MicroSD J45S9\"/\"${new_ide_cfata_model}\"/"
  sed -i "$core_file" -Ee "s/\"Samsung SSD 980 500GB\"/\"${new_default_model}\"/"

  print_modified "$core_file" "$new_serial"
  print_modified "$core_file" "$new_ide_cd_model"
  print_modified "$core_file" "$new_ide_cfata_model"
  print_modified "$core_file" "$new_default_model"
}

spoof_acpi_table_strings() {
  local pairs=(
    'DELL  ' 'Dell Inc' ' ASUS ' 'Notebook'
    'MSI NB' 'MEGABOOK' 'LENOVO' 'TC-O5Z  '
    'LENOVO' 'CB-01   ' 'SECCSD' 'LH43STAR'
    'LGE   ' 'ICL     '
  )

  if [[ "$CPU_VENDOR" == "amd" ]]; then
    pairs+=('ALASKA' 'A M I ')
  elif [[ "$CPU_VENDOR" == "intel" ]]; then
    pairs+=('INTEL ' 'U Rvp   ')
  fi

  local total_pairs=$(( ${#pairs[@]} / 2 ))
  local random_index=$(( RANDOM % total_pairs * 2 ))

  local appname6=${pairs[$random_index]}
  local appname8=${pairs[$random_index + 1]}

  local file="$(pwd)/include/hw/acpi/aml-build.h"
  sed -i "$file" -e "s/^#define ACPI_BUILD_APPNAME6 \".*\"/#define ACPI_BUILD_APPNAME6 \"${appname6}\"/"
  sed -i "$file" -e "s/^#define ACPI_BUILD_APPNAME8 \".*\"/#define ACPI_BUILD_APPNAME8 \"${appname8}\"/"

  print_modified "$file" ''
  fmtr::format_text '    ' "#define ACPI_BUILD_APPNAME6 '${appname6}'" '' "$TEXT_GREEN"
  fmtr::format_text '    ' "#define ACPI_BUILD_APPNAME8 '${appname8}'" '' "$TEXT_GREEN"
}

spoof_cpuid_manufacturer() {
  local chipset_file
  case "$QEMU_VERSION" in
    "8.2.6") chipset_file="$(pwd)/hw/i386/pc_q35.c" ;;
    "9.2.0") chipset_file="$(pwd)/hw/i386/fw_cfg.c" ;;
    *) fmtr::warn "Unsupported QEMU version: $QEMU_VERSION" ;;
  esac

  local manufacturer=$(sudo dmidecode -t 4 | grep 'Manufacturer:' | awk -F': +' '{print $2}')
  sed -i "$chipset_file" -e "s/smbios_set_defaults(\"[^\"]*\",/smbios_set_defaults(\"${manufacturer}\",/"
  print_modified "$chipset_file" "$manufacturer"
}

compile_qemu() {
  fmtr::log "Configuring build environment"
  ./configure --target-list=x86_64-softmmu \
              --enable-libusb \
              --enable-spice \
              --disable-werror &>> "$LOG_FILE"

  fmtr::log "Building QEMU"
  make -j"$(nproc)" &>> "$LOG_FILE"

  fmtr::log "Installing QEMU"
  sudo make install &>> "$LOG_FILE"
  fmtr::info "Compilation finished!"
}

cleanup() {
  fmtr::log "Cleaning up"
  cd .. && sudo rm -rf "$QEMU_ARCHIVE" "$QEMU_DIR" "$QEMU_SIG"
  cd .. && sudo rmdir --ignore-fail-on-non-empty "$SRC_DIR"
}

main() {
  install_req_pkgs "QEMU"
  acquire_qemu_source
  patch_qemu
  prmt::yes_or_no "$(fmtr::ask 'Build & install QEMU to /usr/local/bin')" && compile_qemu
  ! prmt::yes_or_no "$(fmtr::ask 'Keep QEMU source to make repatching quicker')" && cleanup
}

main
