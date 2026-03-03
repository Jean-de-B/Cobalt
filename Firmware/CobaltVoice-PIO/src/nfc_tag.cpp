/**
 * @file nfc_tag.cpp
 * @brief Tag NFC Type 2 (T2T) hardcoded pour test antenne
 *
 * Le peripherique NFCT du nRF52840 gere automatiquement :
 * - Detection de champ NFC
 * - Protocole NFC-A anticollision (SENS_RES, SDD, SEL_RES)
 * - Envoi du UID (NFCID1) depuis FICR
 *
 * Ce code gere uniquement les commandes T2T apres selection :
 * - READ (0x30) → repond 16 bytes (4 pages)
 *
 * Le tag contient un NDEF Text Record : "Cobalt Voice"
 */

#include "nfc_tag.h"
#include "config.h"
#include <nrf.h>

// === CONSTANTES T2T ===
#define T2T_PAGE_SIZE       4
#define T2T_PAGES           16
#define T2T_MEMORY_SIZE     (T2T_PAGES * T2T_PAGE_SIZE)  // 64 bytes

// Commandes NFC Type 2 Tag
#define T2T_CMD_READ        0x30
#define T2T_CMD_WRITE       0xA2

// Reponses T2T
#define T2T_ACK             0x0A
#define T2T_NAK             0x00

// Frame Delay Time (en ticks @ 13.56 MHz)
#define FDT_MIN             1172
#define FDT_MAX             0xFFFF

// === MEMOIRE DU TAG ===
static uint8_t t2t_memory[T2T_MEMORY_SIZE];

// Buffers NFC (doivent etre en RAM, alignes)
static uint8_t nfc_rx_buf[16] __attribute__((aligned(4)));
static uint8_t nfc_tx_buf[16] __attribute__((aligned(4)));

// Etat
static volatile bool _fieldPresent = false;

// === CONSTRUCTION DE LA MEMOIRE T2T ===
static void buildT2tMemory() {
    memset(t2t_memory, 0, T2T_MEMORY_SIZE);

    // Pages 0-2 : UID + internal (depuis FICR)
    uint32_t th0 = NRF_FICR->NFC.TAGHEADER0;
    uint32_t th1 = NRF_FICR->NFC.TAGHEADER1;
    uint32_t th2 = NRF_FICR->NFC.TAGHEADER2;

    t2t_memory[0]  = (th0 >>  0) & 0xFF;  // UID0
    t2t_memory[1]  = (th0 >>  8) & 0xFF;  // UID1
    t2t_memory[2]  = (th0 >> 16) & 0xFF;  // UID2
    t2t_memory[3]  = (th0 >> 24) & 0xFF;  // BCC0
    t2t_memory[4]  = (th1 >>  0) & 0xFF;  // UID3
    t2t_memory[5]  = (th1 >>  8) & 0xFF;  // UID4
    t2t_memory[6]  = (th1 >> 16) & 0xFF;  // UID5
    t2t_memory[7]  = (th1 >> 24) & 0xFF;  // UID6
    t2t_memory[8]  = (th2 >>  0) & 0xFF;  // BCC1
    t2t_memory[9]  = (th2 >>  8) & 0xFF;  // Internal
    t2t_memory[10] = 0x00;                 // Lock0
    t2t_memory[11] = 0x00;                 // Lock1

    // Page 3 : Capability Container
    t2t_memory[12] = 0xE1;  // NDEF Magic Number
    t2t_memory[13] = 0x10;  // Version 1.0
    t2t_memory[14] = 0x06;  // Taille : 6 × 8 = 48 bytes
    t2t_memory[15] = 0x00;  // Acces lecture/ecriture

    // Pages 4+ : NDEF Message
    // TLV : 03 <len> <NDEF record> FE
    // NDEF Text Record : "Cobalt Voice"
    //   Header : D1 01 0F 54 (MB=1,ME=1,SR=1,TNF=1,TypeLen=1,PayloadLen=15,Type='T')
    //   Payload : 02 66 72 "Cobalt Voice" (UTF-8, lang="fr", 12 chars)
    static const uint8_t ndef[] = {
        0x03, 0x13,                         // NDEF Message TLV, length=19
        0xD1,                               // Record header: MB|ME|SR|TNF=Well-Known
        0x01,                               // Type length = 1
        0x0F,                               // Payload length = 15
        0x54,                               // Type = 'T' (Text)
        0x02,                               // Status: UTF-8, lang code 2 bytes
        0x66, 0x72,                         // Language: "fr"
        0x43, 0x6F, 0x62, 0x61, 0x6C, 0x74, // "Cobalt"
        0x20,                               // " "
        0x56, 0x6F, 0x69, 0x63, 0x65,       // "Voice"
        0xFE                                // Terminator TLV
    };
    memcpy(&t2t_memory[16], ndef, sizeof(ndef));
}

// === PREPARATION RX ===
static void prepareRx() {
    NRF_NFCT->PACKETPTR = (uint32_t)nfc_rx_buf;
    NRF_NFCT->MAXLEN = sizeof(nfc_rx_buf);
    NRF_NFCT->TASKS_ENABLERXDATA = 1;
}

// === ENVOI TX ===
static void sendResponse(const uint8_t* data, uint8_t len) {
    memcpy(nfc_tx_buf, data, len);
    NRF_NFCT->PACKETPTR = (uint32_t)nfc_tx_buf;
    NRF_NFCT->TXD.AMOUNT = (len << 3);  // En bits (bytes × 8)
    NRF_NFCT->TASKS_STARTTX = 1;
}

// === TRAITEMENT COMMANDE READ ===
static void handleReadCommand(uint8_t page) {
    uint8_t response[16];

    // READ retourne 4 pages (16 bytes) avec wrapping
    for (int i = 0; i < 16; i++) {
        uint8_t addr = ((page * T2T_PAGE_SIZE) + i) % T2T_MEMORY_SIZE;
        response[i] = t2t_memory[addr];
    }

    sendResponse(response, 16);
}

// === INTERRUPT HANDLER NFCT ===
extern "C" void NFCT_IRQHandler(void) {

    // --- Champ NFC detecte ---
    if (NRF_NFCT->EVENTS_FIELDDETECTED) {
        NRF_NFCT->EVENTS_FIELDDETECTED = 0;
        _fieldPresent = true;
        NRF_NFCT->TASKS_ACTIVATE = 1;
    }

    // --- Champ NFC perdu ---
    if (NRF_NFCT->EVENTS_FIELDLOST) {
        NRF_NFCT->EVENTS_FIELDLOST = 0;
        _fieldPresent = false;
        NRF_NFCT->TASKS_SENSE = 1;
    }

    // --- Tag selectionne (anticollision terminee) ---
    if (NRF_NFCT->EVENTS_SELECTED) {
        NRF_NFCT->EVENTS_SELECTED = 0;
        prepareRx();
    }

    // --- Frame RX complete ---
    if (NRF_NFCT->EVENTS_RXFRAMEEND) {
        NRF_NFCT->EVENTS_RXFRAMEEND = 0;

        // Nombre de bytes recus
        uint32_t rxBits = NRF_NFCT->RXD.AMOUNT;
        uint8_t rxBytes = (rxBits >> 3) & 0x1FF;

        if (rxBytes >= 2 && nfc_rx_buf[0] == T2T_CMD_READ) {
            // READ command : page number dans le 2e byte
            handleReadCommand(nfc_rx_buf[1]);
        } else {
            // Commande non supportee → NAK
            uint8_t nak = T2T_NAK;
            NRF_NFCT->PACKETPTR = (uint32_t)&nak;
            NRF_NFCT->TXD.AMOUNT = 4;  // NAK = 4 bits
            NRF_NFCT->TASKS_STARTTX = 1;
        }
    }

    // --- Frame TX complete ---
    if (NRF_NFCT->EVENTS_TXFRAMEEND) {
        NRF_NFCT->EVENTS_TXFRAMEEND = 0;
        prepareRx();  // Pret pour la prochaine commande
    }

    // --- Erreur ---
    if (NRF_NFCT->EVENTS_ERROR) {
        NRF_NFCT->EVENTS_ERROR = 0;
        // Reset : retour en mode sensing
        NRF_NFCT->TASKS_SENSE = 1;
    }

    // --- Collision (anticollision geree par hardware) ---
    if (NRF_NFCT->EVENTS_COLLISION) {
        NRF_NFCT->EVENTS_COLLISION = 0;
    }
}

// === SETUP ===
bool nfcTagSetup() {
    // Verifier que les pins NFC sont en mode NFC (UICR)
    // Messages toujours affiches (critique pour diagnostic)
    Serial.printf("[NFC] UICR NFCPINS = 0x%08lX\n", NRF_UICR->NFCPINS);
    if ((NRF_UICR->NFCPINS & 1) == 0) {
        Serial.println("[NFC] ERREUR: pins en mode GPIO! NFC desactive.");
        Serial.println("[NFC] Il faut reprogrammer UICR pour activer NFC.");
        return false;
    }

    // Construire la memoire T2T
    buildT2tMemory();

    // Configurer le NFCID1 (UID 7 bytes depuis FICR)
    NRF_NFCT->NFCID1_2ND_LAST = NRF_FICR->NFC.TAGHEADER0;
    NRF_NFCT->NFCID1_LAST     = NRF_FICR->NFC.TAGHEADER1;

    // SENSRES (ATQA) : bit_frame_sdd=00001, nfcid1_size=01 (double=7 bytes)
    NRF_NFCT->SENSRES = (1 << 0) | (1 << 6);

    // SELRES (SAK) : 0x00 = Type 2 Tag, pas d'ISO-DEP
    NRF_NFCT->SELRES = 0x00;

    // Frame Delay Time
    NRF_NFCT->FRAMEDELAYMIN  = FDT_MIN;
    NRF_NFCT->FRAMEDELAYMAX  = FDT_MAX;
    NRF_NFCT->FRAMEDELAYMODE = 3;  // WINDOWGRID

    // Configuration TX : parite + SOF + CRC automatiques
    NRF_NFCT->TXD.FRAMECONFIG = (1 << 0) |  // Parity
                                 (1 << 2) |  // SOF
                                 (1 << 4);   // CRC16TX

    // Configuration RX : parite + SOF + CRC automatiques
    NRF_NFCT->RXD.FRAMECONFIG = (1 << 0) |  // Parity
                                 (1 << 2) |  // SOF
                                 (1 << 4);   // CRC16RX

    // Activer les interrupts NFCT
    NRF_NFCT->INTENSET = (1 << 1)  |  // FIELDDETECTED
                          (1 << 2)  |  // FIELDLOST
                          (1 << 4)  |  // COLLISION
                          (1 << 10) |  // SELECTED
                          (1 << 15) |  // RXFRAMEEND
                          (1 << 7)  |  // TXFRAMEEND
                          (1 << 16);   // ERROR

    // Priorite ISR compatible SoftDevice (6 = safe)
    NVIC_SetPriority(NFCT_IRQn, 6);
    NVIC_ClearPendingIRQ(NFCT_IRQn);
    NVIC_EnableIRQ(NFCT_IRQn);

    // Demarrer la detection de champ
    NRF_NFCT->TASKS_SENSE = 1;

    Serial.println("[NFC] Tag Type 2 active (NDEF: Cobalt Voice)");
    return true;
}

bool nfcTagIsFieldPresent() {
    return _fieldPresent;
}
