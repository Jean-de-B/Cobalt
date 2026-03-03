"""
Generate the Cobalt Task strategic vision PDF.
Explores the future potential: self-hosted AI, agent architecture, product roadmap.
"""

from fpdf import FPDF
import os

# --- COLORS ---
COBALT_DARK = (0, 48, 107)
COBALT_MID = (0, 90, 170)
COBALT_BRIGHT = (30, 120, 220)
COBALT_LIGHT = (220, 235, 252)
WHITE = (255, 255, 255)
BLACK = (30, 30, 30)
GRAY = (100, 100, 110)
LIGHT_GRAY = (240, 242, 245)
GREEN = (0, 180, 100)
DARK_GREEN = (20, 120, 60)
ORANGE = (232, 145, 58)
CYAN = (0, 172, 193)
PURPLE = (123, 97, 255)
RED_SOFT = (220, 60, 60)

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
LOGO_PATH = os.path.join(SCRIPT_DIR, "..", "assets", "logo_icon.png")
OUTPUT_DIR = SCRIPT_DIR


class VisionPDF(FPDF):

    def __init__(self, title_text=""):
        super().__init__()
        self.title_text = title_text
        self.set_auto_page_break(auto=True, margin=25)

    def header(self):
        if self.page_no() == 1:
            return
        self.set_fill_color(*COBALT_DARK)
        self.rect(0, 0, 210, 2, "F")
        self.set_y(6)
        self.set_font("Helvetica", "I", 8)
        self.set_text_color(*GRAY)
        self.cell(0, 5, f"Cobalt Task  -  {self.title_text}", align="L")
        self.ln(10)

    def footer(self):
        self.set_y(-15)
        self.set_font("Helvetica", "I", 8)
        self.set_text_color(*GRAY)
        self.cell(0, 10, f"Page {self.page_no()}/{{nb}}", align="C")

    def cover_page(self):
        self.add_page()
        for i in range(160):
            t = i / 160
            r = int(COBALT_DARK[0] * (1 - t) + 10 * t)
            g = int(COBALT_DARK[1] * (1 - t) + 15 * t)
            b = int(COBALT_DARK[2] * (1 - t) + 40 * t)
            self.set_fill_color(r, g, b)
            self.rect(0, i * 0.75, 210, 0.76, "F")

        if os.path.exists(LOGO_PATH):
            self.image(LOGO_PATH, x=80, y=12, w=50)

        self.set_y(72)
        self.set_font("Helvetica", "B", 28)
        self.set_text_color(*WHITE)
        self.cell(0, 12, "Cobalt Task", align="C", new_x="LMARGIN", new_y="NEXT")

        self.set_font("Helvetica", "", 18)
        self.set_text_color(180, 210, 255)
        self.cell(0, 10, "Document de vision strategique", align="C", new_x="LMARGIN", new_y="NEXT")

        self.ln(8)
        self.set_draw_color(80, 140, 220)
        self.line(60, self.get_y(), 150, self.get_y())
        self.ln(8)

        self.set_font("Helvetica", "", 12)
        self.set_text_color(200, 220, 255)
        self.multi_cell(0, 7, (
            "D'un assistant vocal personnel\n"
            "a une plateforme d'agent IA self-hosted\n"
            "accessible a tous"
        ), align="C")

        self.set_y(220)
        self.set_font("Helvetica", "", 10)
        self.set_text_color(150, 170, 200)
        self.cell(0, 6, "Fevrier 2026  -  Document interne", align="C", new_x="LMARGIN", new_y="NEXT")

    def chapter_page(self, number, title, subtitle=""):
        """Full-width chapter divider page."""
        self.add_page()
        self.set_fill_color(*COBALT_DARK)
        self.rect(0, 0, 210, 55, "F")
        self.set_fill_color(*COBALT_BRIGHT)
        self.rect(0, 55, 210, 2, "F")

        self.set_y(15)
        self.set_font("Helvetica", "", 14)
        self.set_text_color(150, 190, 255)
        self.cell(0, 8, f"PARTIE {number}", align="C", new_x="LMARGIN", new_y="NEXT")
        self.set_font("Helvetica", "B", 22)
        self.set_text_color(*WHITE)
        self.cell(0, 12, title, align="C", new_x="LMARGIN", new_y="NEXT")
        if subtitle:
            self.set_font("Helvetica", "I", 11)
            self.set_text_color(180, 210, 255)
            self.cell(0, 8, subtitle, align="C")

        self.set_y(68)

    def section(self, text):
        self.ln(4)
        if self.get_y() > 250:
            self.add_page()
        y = self.get_y()
        self.set_fill_color(*COBALT_BRIGHT)
        self.rect(10, y, 3, 11, "F")
        self.set_xy(16, y)
        self.set_font("Helvetica", "B", 16)
        self.set_text_color(*COBALT_DARK)
        self.cell(0, 11, text)
        self.ln(13)
        self.set_draw_color(*COBALT_LIGHT)
        self.line(10, self.get_y(), 200, self.get_y())
        self.ln(4)

    def sub(self, text):
        self.ln(2)
        if self.get_y() > 262:
            self.add_page()
        self.set_font("Helvetica", "B", 11)
        self.set_text_color(*COBALT_MID)
        self.cell(0, 6, text, new_x="LMARGIN", new_y="NEXT")
        self.ln(2)

    def text(self, t):
        self.set_font("Helvetica", "", 10)
        self.set_text_color(*BLACK)
        self.multi_cell(0, 5.5, t)
        self.ln(2)

    def bold(self, t):
        self.set_font("Helvetica", "B", 10)
        self.set_text_color(*BLACK)
        self.multi_cell(0, 5.5, t)
        self.ln(1)

    def info(self, t):
        self.ln(1)
        y = self.get_y()
        if y > 260:
            self.add_page()
            y = self.get_y()
        self.set_fill_color(*COBALT_LIGHT)
        self.set_font("Helvetica", "I", 9)
        h = max(len(t) / 72 * 5 + t.count('\n') * 5 + 8, 14)
        self.rect(15, y, 170, h, "F")
        self.set_fill_color(*COBALT_BRIGHT)
        self.rect(15, y, 2.5, h, "F")
        self.set_xy(20, y + 2)
        self.set_text_color(40, 60, 90)
        self.multi_cell(160, 5, t)
        self.set_y(y + h + 2)

    def warn(self, t):
        self.ln(1)
        y = self.get_y()
        if y > 260:
            self.add_page()
            y = self.get_y()
        self.set_fill_color(255, 243, 224)
        self.set_font("Helvetica", "", 9)
        h = max(len(t) / 72 * 5 + t.count('\n') * 5 + 8, 14)
        self.rect(15, y, 170, h, "F")
        self.set_fill_color(*ORANGE)
        self.rect(15, y, 2.5, h, "F")
        self.set_xy(20, y + 2)
        self.set_text_color(100, 60, 0)
        self.multi_cell(160, 5, t)
        self.set_y(y + h + 2)

    def green_box(self, t):
        self.ln(1)
        y = self.get_y()
        if y > 260:
            self.add_page()
            y = self.get_y()
        self.set_fill_color(225, 250, 235)
        self.set_font("Helvetica", "", 9)
        h = max(len(t) / 72 * 5 + t.count('\n') * 5 + 8, 14)
        self.rect(15, y, 170, h, "F")
        self.set_fill_color(*GREEN)
        self.rect(15, y, 2.5, h, "F")
        self.set_xy(20, y + 2)
        self.set_text_color(15, 80, 40)
        self.multi_cell(160, 5, t)
        self.set_y(y + h + 2)

    def row(self, cols, widths, header=False, fill=None):
        y = self.get_y()
        if y > 272:
            self.add_page()
            y = self.get_y()
        h = 7
        if header:
            self.set_fill_color(*COBALT_DARK)
            self.set_text_color(*WHITE)
            self.set_font("Helvetica", "B", 8.5)
        else:
            self.set_fill_color(*(fill or WHITE))
            self.set_text_color(*BLACK)
            self.set_font("Helvetica", "", 8.5)
        x = 15
        for col, w in zip(cols, widths):
            self.set_xy(x, y)
            self.cell(w, h, f" {col}", fill=True)
            x += w
        self.ln(h)

    def pipeline_block(self, label, content, color):
        y = self.get_y()
        if y > 258:
            self.add_page()
            y = self.get_y()
        self.set_fill_color(*color)
        self.rect(15, y, 170, 6.5, "F")
        self.set_xy(17, y)
        self.set_font("Helvetica", "B", 8.5)
        self.set_text_color(*WHITE)
        self.cell(0, 6.5, label)
        self.ln(7)

        self.set_fill_color(245, 247, 250)
        y2 = self.get_y()
        self.set_font("Helvetica", "", 8.5)
        self.set_text_color(*BLACK)
        lines = content.split('\n')
        h = len(lines) * 5 + 4
        self.rect(15, y2, 170, h, "F")
        self.set_fill_color(*color)
        self.rect(15, y2, 2, h, "F")
        self.set_xy(20, y2 + 2)
        self.multi_cell(160, 5, content)
        self.set_y(y2 + h + 2)

    def arrow_down(self):
        y = self.get_y()
        if y > 275:
            self.add_page()
            return
        self.set_font("Helvetica", "B", 12)
        self.set_text_color(*COBALT_BRIGHT)
        self.set_x(95)
        self.cell(20, 6, "v", align="C")
        self.ln(6)


def generate_vision():
    pdf = VisionPDF("Vision strategique")
    pdf.alias_nb_pages()

    # =========================================================================
    # COVER
    # =========================================================================
    pdf.cover_page()

    # =========================================================================
    # TABLE DES MATIERES
    # =========================================================================
    pdf.add_page()
    pdf.section("Sommaire")
    pdf.ln(4)

    toc = [
        ("1", "Ou en est Cobalt aujourd'hui", "Etat des lieux technique"),
        ("2", "La vision : Cobalt Agent Platform", "Ce que le projet peut devenir"),
        ("3", "Le stack IA cible", "Pipeline voix de nouvelle generation"),
        ("4", "Architecture serveur self-hosted", "Backend multi-utilisateurs"),
        ("5", "Positionnement concurrentiel", "Pourquoi Cobalt a sa place"),
        ("6", "Roadmap et couts", "Plan de route en 5 phases"),
    ]
    for num, title, desc in toc:
        y = pdf.get_y()
        pdf.set_font("Helvetica", "B", 12)
        pdf.set_text_color(*COBALT_DARK)
        pdf.cell(10, 8, num)
        pdf.cell(90, 8, title)
        pdf.set_font("Helvetica", "I", 10)
        pdf.set_text_color(*GRAY)
        pdf.cell(80, 8, desc)
        pdf.ln(10)

    # =========================================================================
    # PARTIE 1 : ETAT DES LIEUX
    # =========================================================================
    pdf.chapter_page("1", "Ou en est Cobalt aujourd'hui", "Etat des lieux technique et produit")

    pdf.section("Architecture actuelle")
    pdf.text("Cobalt Task est aujourd'hui un assistant vocal 100% client-side, tourne sur Android, sans aucun serveur propre. Le telephone fait tout : capturer la voix, transcrire, analyser, executer les actions, et synchroniser avec Google.")

    pdf.sub("Pipeline actuel")
    pdf.pipeline_block("1. CAPTURE AUDIO", "Bracelet BLE (nRF52840) ou micro du telephone\nADPCM 4-bit, 16 kHz mono -> decompression PCM sur le telephone", COBALT_DARK)
    pdf.arrow_down()
    pdf.pipeline_block("2. TRANSCRIPTION (cloud)", "Groq API - Whisper Large V3\nLatence : ~500ms | Cout : ~0.006$/min | Langues : 99", COBALT_MID)
    pdf.arrow_down()
    pdf.pipeline_block("3. ANALYSE IA (cloud)", "Groq API - Llama 3.1 8B Instant\nClassification en 1 shot (few-shot prompting)\n5 categories notes + 10 intents actions | Temperature 0.1-0.3", COBALT_BRIGHT)
    pdf.arrow_down()
    pdf.pipeline_block("4. EXECUTION (local)", "Actions Android natives (SMS, appels, alarmes, volume, GPS...)\n+ Sync Google (Tasks, Calendar, Contacts, Docs)\n+ Spotify Web API", GREEN)

    pdf.ln(4)
    pdf.section("Forces et limites")

    w = [85, 85]
    pdf.row(["Forces", "Limites"], w, header=True)
    pdf.row(["Zero serveur a maintenir", "1 seule cle API partagee (rate limits)"], w, fill=LIGHT_GRAY)
    pdf.row(["Fonctionne offline (actions locales)", "Aucune memoire conversationnelle"], w)
    pdf.row(["Integration Google profonde", "Classification shallow (pas de raisonnement)"], w, fill=LIGHT_GRAY)
    pdf.row(["Hardware BLE custom (bracelet)", "Pas de personnalisation par utilisateur"], w)
    pdf.row(["15+ actions vocales differentes", "Sync Google unidirectionnelle"], w, fill=LIGHT_GRAY)
    pdf.row(["TTS de confirmation ecran verrouille", "Cles API dans l'APK (securite)"], w)

    pdf.ln(4)
    pdf.info("En resume : Cobalt est un excellent prototype single-user.\nPour en faire une plateforme multi-utilisateurs, il faut un cerveau central sur un serveur.")

    # =========================================================================
    # PARTIE 2 : LA VISION
    # =========================================================================
    pdf.chapter_page("2", "La vision : Cobalt Agent Platform", "Un assistant personnel IA, self-hosted, open, intelligent")

    pdf.section("Le concept")
    pdf.text("L'idee : transformer Cobalt d'un outil personnel en une plateforme d'agent IA que chacun peut heberger soi-meme. Un assistant qui tourne sur TON serveur (ou un VPS a 5 euros/mois), auquel tes amis se connectent via l'app Cobalt sur leur telephone.")

    pdf.text("Imagine une fusion entre :")
    pdf.bold("- OpenClaw : un agent IA self-hosted qui a explose (400 000 utilisateurs en 2 mois)\n- Gemini / Bixby : un assistant quotidien integre au smartphone\n- MCP (Model Context Protocol) : un standard d'integration ouvert")

    pdf.text("La difference avec les assistants existants :")

    w = [55, 55, 55]
    pdf.row(["Cobalt", "Gemini / Siri", "OpenClaw"], w, header=True)
    pdf.row(["Self-hosted (tes donnees)", "Cloud (donnees chez Google/Apple)", "Self-hosted"], w, fill=LIGHT_GRAY)
    pdf.row(["App smartphone native", "App smartphone native", "Telegram/Signal (pas d'app)"], w)
    pdf.row(["Actions Android profondes", "Actions profondes", "Fichiers + web (pas mobile)"], w, fill=LIGHT_GRAY)
    pdf.row(["Bracelet BLE hardware", "Pas de hardware tiers", "Pas de hardware"], w)
    pdf.row(["Open + personnalisable", "Ferme (black box)", "Open source"], w, fill=LIGHT_GRAY)
    pdf.row(["Francais natif", "Anglais d'abord", "Multi-langue"], w)

    pdf.ln(3)
    pdf.green_box("Le positionnement unique de Cobalt : le seul assistant vocal self-hosted avec une app smartphone native ET du hardware custom (bracelet BLE).")

    pdf.section("Les 3 piliers de la vision")

    pdf.sub("Pilier 1 : Le Cerveau (serveur IA)")
    pdf.text("Un backend intelligent qui heberge le LLM, gere la memoire conversationnelle, les profils utilisateurs, et orchestre les outils via MCP. Chaque utilisateur a son contexte, ses preferences, son historique.")

    pdf.sub("Pilier 2 : Le Corps (app Cobalt + bracelet)")
    pdf.text("L'application Android reste le point de contact avec le monde reel : micro, haut-parleur, capteurs, actions natives (SMS, appels, GPS, alarmes). Le bracelet ajoute un input hardware mains-libres. Le serveur dit QUOI faire, le telephone fait.")

    pdf.sub("Pilier 3 : Les Mains (integrations MCP)")
    pdf.text("Via le standard MCP (Model Context Protocol), le serveur peut se connecter a n'importe quel outil : Google Tasks, Notion, Slack, domotique, API meteo, Spotify... sans ecrire de code specifique pour chaque service. MCP est devenu le standard de l'industrie (Linux Foundation, soutenu par OpenAI, Google, Microsoft).")

    # =========================================================================
    # PARTIE 3 : STACK IA CIBLE
    # =========================================================================
    pdf.chapter_page("3", "Le stack IA cible", "Pipeline voix de nouvelle generation")

    pdf.section("Pipeline voix evolue")
    pdf.text("Le pipeline actuel (STT -> classification -> action) est correct mais limité. Le pipeline cible ajoute des couches d'intelligence entre chaque etape.")

    pdf.ln(2)
    pdf.pipeline_block("1. VAD - Voice Activity Detection", "Silero VAD (30ms, open-source)\nDetecte quand l'utilisateur parle/s'arrete -> decoupe l'audio en segments\nElimine les silences, optimise les appels STT", (80, 80, 100))
    pdf.arrow_down()
    pdf.pipeline_block("2. STT - Speech-to-Text", "Cloud : Deepgram Nova-3 (<300ms, streaming) ou Groq Whisper\nLocal : Sherpa ONNX (offline fallback)\nNouveau : gpt-4o-transcribe (meilleur WER global)\nStreaming = resultats partiels en temps reel", COBALT_DARK)
    pdf.arrow_down()
    pdf.pipeline_block("3. NLU + CONTEXTE (nouvelle couche)", "Enrichissement du texte AVANT le LLM :\n- Injection du contexte utilisateur (5 derniers messages, profil, preferences)\n- Resolution d'entites (\"maman\" -> Marie Dupont, 06 12 34 56 78)\n- Detection d'emotion (frustration, urgence, question)\n- RAG : recherche dans l'historique (\"comme la derniere fois\")", PURPLE)
    pdf.arrow_down()
    pdf.pipeline_block("4. LLM - Raisonnement", "Modele principal : Claude Sonnet / Llama 3.3 70B / Mixtral (self-hosted)\nChain-of-thought pour les requetes complexes\nMulti-turn : \"Annule ca\" comprend le contexte\nTool calling natif : le LLM decide quels outils appeler via MCP", COBALT_BRIGHT)
    pdf.arrow_down()
    pdf.pipeline_block("5. ORCHESTRATEUR D'ACTIONS", "Route les decisions du LLM vers :\n- Actions locales (telephone) : SMS, appels, alarmes, GPS\n- Actions cloud (serveur) : Google, Spotify, Notion, domotique\n- Actions MCP : n'importe quel serveur MCP connecte\nGere les confirmations, les rollbacks, le retry", GREEN)
    pdf.arrow_down()
    pdf.pipeline_block("6. TTS - Text-to-Speech", "Kokoro TTS v1.0 (82M params, Apache 2.0, francais natif)\n96x temps reel, self-hostable, 54 voix\nAlternative : ElevenLabs (meilleure qualite, payant)\nStreaming : commence a parler avant la fin de la generation", ORANGE)

    pdf.ln(3)
    pdf.section("Les nouvelles couches-cles")

    pdf.sub("Couche NLU + Contexte (entre STT et LLM)")
    pdf.text("C'est LA couche qui transforme un classifieur basique en assistant intelligent. Aujourd'hui, le LLM recoit le texte brut et doit tout deviner. Demain :")

    pdf.text('Exemple actuel :\nUtilisateur : "Dis-lui que j\'arrive"\nLLM recoit : "Dis-lui que j\'arrive" -> Echec (qui est "lui" ?)')

    pdf.text('Exemple avec couche NLU :\nUtilisateur : "Dis-lui que j\'arrive"\nNLU injecte : Dernier contact mentionne = Pierre (il y a 2 min)\nLLM recoit : [Contexte: dernier contact = Pierre Dupont, 06...] "Dis-lui que j\'arrive"\n-> SMS a Pierre : "J\'arrive"')

    pdf.sub("Memoire conversationnelle")
    pdf.text("3 niveaux de memoire, comme un humain :")
    pdf.text("1. Memoire de travail (session) : les 5-10 derniers echanges. Permet le multi-turn.\n2. Memoire episodique (jours) : historique des 30 derniers jours. Permet \"comme la derniere fois\".\n3. Memoire semantique (permanente) : profil utilisateur, preferences, contacts frequents. Permet la personnalisation.")

    pdf.sub("RAG (Retrieval-Augmented Generation)")
    pdf.text("Avant chaque appel au LLM, le serveur cherche dans l'historique de l'utilisateur les informations pertinentes. Si tu dis \"ajoute du lait a la liste\", le RAG retrouve ta derniere liste de courses et y ajoute le lait au lieu d'en creer une nouvelle.")

    # =========================================================================
    # PARTIE 4 : ARCHITECTURE SERVEUR
    # =========================================================================
    pdf.chapter_page("4", "Architecture serveur self-hosted", "Backend multi-utilisateurs avec inference locale")

    pdf.section("Vue d'ensemble")
    pdf.text("Le serveur Cobalt est le cerveau central. Il recoit les requetes de l'app, raisonne, et renvoie des instructions d'action. L'app reste le corps qui execute.")

    pdf.ln(2)
    pdf.pipeline_block("COBALT SERVER", (
        "FastAPI (Python) ou Rust (performance)\n"
        "- Auth : JWT tokens par utilisateur\n"
        "- Inference : vLLM (Llama 70B Q4 ou Mixtral) sur GPU\n"
        "- STT : Whisper self-hosted ou Deepgram API\n"
        "- TTS : Kokoro self-hosted (82M params)\n"
        "- Memoire : PostgreSQL + pgvector (RAG)\n"
        "- Outils : MCP servers (Google, Spotify, Notion...)\n"
        "- File d'attente : Redis (jobs async)\n"
        "- Monitoring : Prometheus + Grafana"
    ), COBALT_DARK)

    pdf.ln(2)
    pdf.pipeline_block("COBALT APP (Android)", (
        "Client leger :\n"
        "- Capture audio (micro / bracelet BLE)\n"
        "- Envoie audio au serveur via WebSocket\n"
        "- Recoit les instructions d'action\n"
        "- Execute localement (SMS, appels, alarmes, GPS)\n"
        "- Cache local SQLite (mode hors-ligne)\n"
        "- TTS local en fallback"
    ), GREEN)

    pdf.section("Options d'hebergement")

    w = [40, 35, 35, 30, 30]
    pdf.row(["Config", "GPU", "Users max", "Cout/mois", "Modele"], w, header=True)
    pdf.row(["VPS basique", "Aucun (CPU)", "5-10", "5-15 EUR", "Llama 3B Q4"], w, fill=LIGHT_GRAY)
    pdf.row(["VPS GPU", "RTX 4090 24GB", "10-30", "50-250 EUR", "Llama 8B Q4"], w)
    pdf.row(["Serveur dedie", "RTX 4090 24GB", "20-50", "250-500 EUR", "Llama 70B Q4"], w, fill=LIGHT_GRAY)
    pdf.row(["Cloud GPU", "A100 80GB", "50-100", "500-2000 EUR", "Llama 70B FP16"], w)
    pdf.row(["Hybride", "CPU local + API", "10-100", "100-300 EUR", "Cloud fallback"], w, fill=LIGHT_GRAY)

    pdf.ln(3)
    pdf.info("L'option hybride est la plus realiste pour commencer : un petit serveur CPU qui gere l'orchestration et la memoire, avec des appels API (Groq, Deepgram) pour l'inference lourde. Quand le volume justifie un GPU, on migre l'inference en local.")

    pdf.section("Architecture hybride recommandee (Phase 1)")
    pdf.text("Pour servir 10-30 utilisateurs sans GPU :")

    pdf.pipeline_block("SERVEUR (VPS 4 vCPU, 8 Go RAM, ~15 EUR/mois)", (
        "FastAPI : orchestration, auth, memoire, routing\n"
        "PostgreSQL : utilisateurs, historique, profils\n"
        "Redis : cache + file d'attente\n"
        "Appels API : Groq (STT + LLM) / Deepgram (STT streaming)"
    ), COBALT_MID)

    pdf.text("Cout estime pour 10 utilisateurs actifs :")
    w = [60, 50, 50]
    pdf.row(["Poste", "Cout/mois", "Notes"], w, header=True)
    pdf.row(["VPS (Hetzner/OVH)", "15 EUR", "4 vCPU, 8 Go RAM"], w, fill=LIGHT_GRAY)
    pdf.row(["Groq API", "0-5 EUR", "Free tier genereux"], w)
    pdf.row(["Deepgram STT", "0-10 EUR", "Free tier 200h/mois"], w, fill=LIGHT_GRAY)
    pdf.row(["PostgreSQL", "0 EUR", "Sur le meme VPS"], w)
    pdf.row(["Domaine + SSL", "1 EUR", "Let's Encrypt gratuit"], w, fill=LIGHT_GRAY)
    pdf.row(["TOTAL", "15-30 EUR/mois", ""], w, fill=(220, 235, 252))

    pdf.ln(2)
    pdf.green_box("15 a 30 EUR par mois pour servir 10 amis avec un assistant IA personnel complet.\nC'est moins cher qu'un abonnement Netflix.")

    pdf.section("Securite et multi-tenancy")
    pdf.text("Chaque utilisateur a :")
    pdf.text("- Un compte avec JWT (login email + mot de passe, ou Google SSO)\n- Ses propres tokens Google/Spotify (stockes chiffres cote serveur)\n- Son propre espace memoire (historique, preferences, contacts)\n- Son propre quota d'appels API (rate limiting par utilisateur)")

    pdf.text("Les cles API (Groq, Deepgram, Maps) restent sur le serveur, jamais dans l'APK. L'app ne connait que l'URL du serveur et le token JWT de l'utilisateur.")

    pdf.warn("Point d'attention RGPD : le serveur stocke des transcriptions vocales et des donnees personnelles (contacts, calendrier). Prevoir une politique de confidentialite et un mecanisme de suppression des donnees.")

    # =========================================================================
    # PARTIE 5 : POSITIONNEMENT CONCURRENTIEL
    # =========================================================================
    pdf.chapter_page("5", "Positionnement concurrentiel", "Pourquoi Cobalt a sa place sur le marche")

    pdf.section("Paysage concurrentiel 2026")

    pdf.sub("Les geants : Gemini, Siri, Bixby")
    pdf.text("Google Gemini est devenu l'assistant par defaut sur Samsung Galaxy S26. Siri est en retard : la version IA est repoussee au printemps 2026 (Apple a signe un accord d'1 Md$/an avec Google pour utiliser Gemini). Bixby est en retrait strategique.")

    pdf.text("Leur faiblesse commune : ils sont fermes, opaques, et centrent tout sur leur ecosysteme. Impossible de savoir ce qu'ils font de tes donnees. Impossible de les personnaliser.")

    pdf.sub("Le phenomene OpenClaw")
    pdf.text("OpenClaw (novembre 2025) a prouve qu'il existe une demande massive pour un assistant IA self-hosted. 400 000 utilisateurs en 2 mois, 60 000 etoiles GitHub en 72h. Mais il a des limites : pas d'app native, pas d'integration telephone, 512 vulnerabilites de securite trouvees en audit.")

    pdf.sub("Les startups voix")
    pdf.text("ElevenLabs (3.3 Md$ de valorisation), Vapi, Pipecat... se concentrent sur les agents telephoniques pour entreprises (call centers, support client). Aucun ne cible l'assistant personnel sur smartphone.")

    pdf.section("Le creneau de Cobalt")

    pdf.green_box("Cobalt occupe un creneau unique : le SEUL projet qui combine :\n- Self-hosted (donnees chez toi)\n- App smartphone native (pas un chatbot Telegram)\n- Actions Android profondes (SMS, appels, alarmes, GPS)\n- Hardware custom (bracelet BLE)\n- Francais natif comme langue premiere\n- Open source et personnalisable")

    pdf.text("Ce creneau est vide. Ni Google, ni Apple, ni OpenClaw ne l'occupent.")

    pdf.sub("5 niches a forte demande")
    pdf.text("1. Les utilisateurs soucieux de leur vie privee (post-Snowden, anti-GAFAM)\n2. Le marche francophone mal servi par les assistants anglophones\n3. Les bricoleurs / makers qui veulent personnaliser leur assistant\n4. Les petites equipes / familles qui veulent un assistant partage\n5. Les utilisateurs de montres connectees / wearables DIY")

    # =========================================================================
    # PARTIE 6 : ROADMAP
    # =========================================================================
    pdf.chapter_page("6", "Roadmap et couts", "Plan de route en 5 phases")

    pdf.section("Vue d'ensemble des phases")

    w = [22, 60, 40, 45]
    pdf.row(["Phase", "Objectif", "Duree", "Cout infra"], w, header=True)
    pdf.row(["1", "Backend API Gateway", "2-3 semaines", "15 EUR/mois (VPS)"], w, fill=LIGHT_GRAY)
    pdf.row(["2", "Memoire + contexte", "1-2 semaines", "+0 EUR"], w)
    pdf.row(["3", "Profils + personnalisation", "2 semaines", "+0 EUR"], w, fill=LIGHT_GRAY)
    pdf.row(["4", "Integrations MCP", "2-3 semaines", "+0-10 EUR"], w)
    pdf.row(["5", "Inference self-hosted", "3-4 semaines", "+50-250 EUR (GPU)"], w, fill=LIGHT_GRAY)

    pdf.section("Phase 1 : Backend API Gateway (fondation)")
    pdf.text("Objectif : extraire l'intelligence du telephone vers un serveur central. L'app devient un client leger.")

    pdf.text("Livrables :\n- Serveur FastAPI avec auth JWT\n- Endpoints : /transcribe, /analyze, /execute\n- Proxy des appels Groq (les cles API quittent l'APK)\n- Base PostgreSQL : utilisateurs, sessions\n- L'app appelle le serveur au lieu de Groq directement")

    pdf.info("Impact : les cles API ne sont plus dans l'APK. Chaque utilisateur a son propre compte. Le rate limiting est gere par le serveur, plus par Groq.")

    pdf.section("Phase 2 : Memoire conversationnelle")
    pdf.text("Objectif : le LLM se souvient de ce que l'utilisateur a dit avant.")

    pdf.text('Livrables :\n- Table "conversation_history" (user_id, text, intent, result, timestamp)\n- Injection des 5 derniers messages dans le prompt LLM\n- "Annule ca" fonctionne enfin (le LLM voit le contexte)\n- "Comme la derniere fois" retrouve l\'historique pertinent')

    pdf.green_box('Avant : "Annule ca" -> rien (pas de contexte)\nApres : "Annule ca" -> annule le rendez-vous cree il y a 30 secondes')

    pdf.section("Phase 3 : Profils et personnalisation")
    pdf.text("Objectif : le LLM connait l'utilisateur et s'adapte.")

    pdf.text('Livrables :\n- Profil utilisateur : contacts frequents, apps preferees, horaires habituels\n- Alias de contacts : "maman" = Marie Dupont, 06...\n- Apprentissage des preferences : "toujours envoyer par WhatsApp a Pierre"\n- A/B testing de prompts (mesurer le taux de correction)')

    pdf.section("Phase 4 : Integrations MCP")
    pdf.text("Objectif : connecter le serveur a n'importe quel service via le standard MCP.")

    pdf.text("Livrables :\n- Client MCP dans le serveur (consomme des MCP servers)\n- MCP servers pour : Google Tasks, Calendar, Contacts, Spotify\n- Possibilite d'ajouter Notion, Slack, Home Assistant, Todoist...\n- Le LLM choisit automatiquement quel outil appeler (tool calling)")

    pdf.info("MCP est le standard de l'industrie (Linux Foundation). En exposant Google Tasks comme MCP server, tu rends Cobalt compatible avec tout l'ecosysteme MCP : Claude Desktop, Cursor, tout agent compatible.")

    pdf.section("Phase 5 : Inference self-hosted")
    pdf.text("Objectif : remplacer les appels API payants par de l'inference locale sur GPU.")

    pdf.text("Livrables :\n- vLLM pour servir Llama 3.3 70B Q4 (ou Mixtral) sur RTX 4090\n- Whisper self-hosted pour la transcription\n- Kokoro TTS pour la synthese vocale (open source, francais)\n- Zero dependance a des API tierces (full self-hosted)")

    pdf.text("Budget hardware :")
    w = [60, 40, 60]
    pdf.row(["Composant", "Prix", "Ce que ca fait"], w, header=True)
    pdf.row(["RTX 4090 24 Go", "~1 600 EUR", "LLM 70B Q4 + Whisper + TTS"], w, fill=LIGHT_GRAY)
    pdf.row(["Ou : cloud GPU", "~250 EUR/mois", "Meme chose sans achat"], w)
    pdf.row(["Alternative CPU", "0 EUR (VPS)", "Llama 3B Q4 (basique)"], w, fill=LIGHT_GRAY)

    pdf.ln(3)
    pdf.warn("La Phase 5 est optionnelle. L'architecture hybride (Phase 1-4) avec des appels API (Groq free tier) fonctionne tres bien pour 10-30 utilisateurs a ~15-30 EUR/mois.")

    # =========================================================================
    # CONCLUSION
    # =========================================================================
    pdf.add_page()
    pdf.section("Conclusion")

    pdf.text("Cobalt Task est deja un assistant vocal fonctionnel et unique. La vision decrite ici transforme ce prototype en une plateforme d'agent IA complete :")

    pdf.ln(2)
    pdf.text("Aujourd'hui : Un telephone qui ecoute et agit (single-user, cles dans l'APK)")
    pdf.text("Phase 1-2 : Un serveur intelligent qui ecoute, comprend le contexte, et agit (multi-user)")
    pdf.text("Phase 3-4 : Un agent personnel qui te connait et se connecte a tout (MCP)")
    pdf.text("Phase 5 : Une plateforme 100% self-hosted, zero dependance (full souverainete)")

    pdf.ln(4)
    pdf.green_box("Le marche de l'assistant personnel IA est domine par des ecosystemes fermes.\nCobalt propose une alternative ouverte, self-hosted, avec du hardware custom.\nC'est un creneau vide, avec une demande prouvee (OpenClaw : 400K utilisateurs).\n\nCout d'entree : 15 EUR/mois pour 10 utilisateurs.\nCout complet : 250 EUR/mois pour 50 utilisateurs avec inference locale.")

    pdf.ln(6)
    pdf.set_font("Helvetica", "B", 14)
    pdf.set_text_color(*COBALT_DARK)
    pdf.cell(0, 10, "La fondation est la. Le reste, c'est de l'execution.", align="C")

    # --- SAVE ---
    path = os.path.join(OUTPUT_DIR, "Cobalt_Task_-_Vision_strategique.pdf")
    pdf.output(path)
    print(f"OK: {path}")
    return path


if __name__ == "__main__":
    print("Generation du PDF Vision strategique...")
    print()
    generate_vision()
    print()
    print("Termine !")
