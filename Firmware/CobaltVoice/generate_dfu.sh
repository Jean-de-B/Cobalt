#!/bin/bash
# =============================================================================
# generate_dfu.sh
# =============================================================================
# Génère un package DFU (.zip) pour mise à jour OTA du Cobalt Voice.
#
# Prérequis:
#   pip install adafruit-nrfutil
#
# Usage:
#   ./generate_dfu.sh                    # Build + génère le .zip
#   ./generate_dfu.sh --skip-build       # Génère le .zip sans rebuilder
#
# Le fichier cobalt_update.zip est placé dans le dossier output/
# Copiez-le dans le dossier Downloads du téléphone pour l'OTA.
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUTPUT_DIR="$SCRIPT_DIR/output"
BUILD_DIR="$SCRIPT_DIR/.pio/build/xiaoblesense"
HEX_FILE="$BUILD_DIR/firmware.hex"
ZIP_FILE="$OUTPUT_DIR/cobalt_update.zip"

# Couleurs
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo "======================================"
echo "  Cobalt Voice - DFU Package Generator"
echo "======================================"

# Vérifier adafruit-nrfutil
if ! command -v adafruit-nrfutil &> /dev/null; then
    echo -e "${RED}ERREUR: adafruit-nrfutil non trouvé${NC}"
    echo "Installation: pip install adafruit-nrfutil"
    exit 1
fi

# Build firmware (sauf si --skip-build)
if [ "$1" != "--skip-build" ]; then
    echo -e "${YELLOW}[1/3] Build du firmware...${NC}"
    cd "$SCRIPT_DIR"
    pio run -e xiaoblesense
    echo -e "${GREEN}[1/3] Build OK${NC}"
else
    echo -e "${YELLOW}[1/3] Build ignoré (--skip-build)${NC}"
fi

# Vérifier que le .hex existe
if [ ! -f "$HEX_FILE" ]; then
    echo -e "${RED}ERREUR: $HEX_FILE introuvable${NC}"
    echo "Lancez d'abord: pio run -e xiaoblesense"
    exit 1
fi

# Créer le dossier output
mkdir -p "$OUTPUT_DIR"

# Générer le package DFU
echo -e "${YELLOW}[2/3] Génération du package DFU...${NC}"
adafruit-nrfutil dfu genpkg \
    --dev-type 0x0052 \
    --sd-req 0x0100 \
    --application "$HEX_FILE" \
    "$ZIP_FILE"

echo -e "${GREEN}[2/3] Package DFU généré: $ZIP_FILE${NC}"

# Afficher les infos
FILE_SIZE=$(wc -c < "$ZIP_FILE")
echo ""
echo -e "${YELLOW}[3/3] Résumé${NC}"
echo "  Fichier:  $ZIP_FILE"
echo "  Taille:   $FILE_SIZE bytes ($(( FILE_SIZE / 1024 )) KB)"
echo ""
echo -e "${GREEN}Pour mettre à jour la montre:${NC}"
echo "  1. Copiez cobalt_update.zip dans Downloads/ du téléphone"
echo "  2. Ouvrez Cobalt Task → icône BLE → Mise à jour firmware"
echo "  3. Appuyez sur 'Lancer'"
echo ""
echo "======================================"
echo -e "${GREEN}  TERMINÉ${NC}"
echo "======================================"
