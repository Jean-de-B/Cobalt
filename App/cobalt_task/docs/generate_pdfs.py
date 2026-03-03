"""
Generate styled PDFs for Cobalt Task documentation.
Uses fpdf2 with custom styling matching the Cobalt brand (blues).
"""

from fpdf import FPDF
import os

# --- COLORS ---
COBALT_DARK = (0, 48, 107)       # #002F6B - bleu fonce
COBALT_MID = (0, 90, 170)        # #005AAA
COBALT_BRIGHT = (30, 120, 220)   # #1E78DC
COBALT_LIGHT = (220, 235, 252)   # #DCEBFC - fond bleu tres clair
WHITE = (255, 255, 255)
BLACK = (30, 30, 30)
GRAY = (100, 100, 110)
LIGHT_GRAY = (240, 242, 245)
GREEN = (0, 180, 100)
ORANGE = (232, 145, 58)
CYAN = (0, 172, 193)
PURPLE = (123, 97, 255)
RED_SOFT = (220, 60, 60)

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
LOGO_PATH = os.path.join(SCRIPT_DIR, "..", "assets", "logo_icon.png")
OUTPUT_DIR = SCRIPT_DIR


class CobaltPDF(FPDF):
    """Base PDF class with Cobalt styling."""

    def __init__(self, title_text=""):
        super().__init__()
        self.title_text = title_text
        self.set_auto_page_break(auto=True, margin=25)
        # Use built-in fonts only (Helvetica)

    def header(self):
        if self.page_no() == 1:
            return  # Cover page has custom header
        # Top bar
        self.set_fill_color(*COBALT_DARK)
        self.rect(0, 0, 210, 2, "F")
        # Page title
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

    def cover_page(self, title, subtitle):
        """Full cover page with Cobalt branding."""
        self.add_page()
        # Blue gradient band at top
        for i in range(120):
            r = int(COBALT_DARK[0] + (COBALT_BRIGHT[0] - COBALT_DARK[0]) * i / 120)
            g = int(COBALT_DARK[1] + (COBALT_BRIGHT[1] - COBALT_DARK[1]) * i / 120)
            b = int(COBALT_DARK[2] + (COBALT_BRIGHT[2] - COBALT_DARK[2]) * i / 120)
            self.set_fill_color(r, g, b)
            self.rect(0, i * 0.75, 210, 0.75, "F")

        # Logo centered
        if os.path.exists(LOGO_PATH):
            self.image(LOGO_PATH, x=75, y=15, w=60)

        # Title
        self.set_y(85)
        self.set_font("Helvetica", "B", 32)
        self.set_text_color(*WHITE)
        self.cell(0, 15, title, align="C", new_x="LMARGIN", new_y="NEXT")

        # Subtitle
        self.set_font("Helvetica", "", 14)
        self.set_text_color(200, 220, 255)
        self.multi_cell(0, 7, subtitle, align="C")

        # Bottom section
        self.set_y(200)
        self.set_font("Helvetica", "", 11)
        self.set_text_color(*BLACK)
        self.cell(0, 8, "Version beta  -  Fevrier 2026", align="C", new_x="LMARGIN", new_y="NEXT")
        self.set_font("Helvetica", "I", 10)
        self.set_text_color(*GRAY)
        self.cell(0, 8, "Document reserve aux testeurs", align="C")

    def section_title(self, number, text):
        """Big section header with blue left border."""
        self.ln(6)
        # Check if enough space
        if self.get_y() > 250:
            self.add_page()
        # Blue accent bar
        y = self.get_y()
        self.set_fill_color(*COBALT_BRIGHT)
        self.rect(10, y, 3, 12, "F")
        # Number circle
        self.set_xy(16, y)
        self.set_font("Helvetica", "B", 20)
        self.set_text_color(*COBALT_DARK)
        label = f"Etape {number}" if number else text
        if number:
            self.cell(0, 12, f"Etape {number}  -  {text}")
        else:
            self.cell(0, 12, text)
        self.ln(14)
        # Thin line
        self.set_draw_color(*COBALT_LIGHT)
        self.line(10, self.get_y(), 200, self.get_y())
        self.ln(4)

    def sub_section(self, text):
        """Subsection header."""
        self.ln(3)
        if self.get_y() > 260:
            self.add_page()
        self.set_font("Helvetica", "B", 12)
        self.set_text_color(*COBALT_MID)
        self.cell(0, 7, text, new_x="LMARGIN", new_y="NEXT")
        self.ln(2)

    def body_text(self, text):
        """Normal body paragraph."""
        self.set_font("Helvetica", "", 10)
        self.set_text_color(*BLACK)
        self.multi_cell(0, 5.5, text)
        self.ln(2)

    def bold_text(self, text):
        """Bold body text."""
        self.set_font("Helvetica", "B", 10)
        self.set_text_color(*BLACK)
        self.multi_cell(0, 5.5, text)
        self.ln(1)

    def tip_box(self, text):
        """Blue tip/info box."""
        self.ln(2)
        y = self.get_y()
        self.set_fill_color(*COBALT_LIGHT)
        # Calculate height needed
        w = 170
        self.set_font("Helvetica", "I", 9)
        nb_lines = len(text) / 75 + text.count('\n') + 1
        h = max(nb_lines * 5 + 6, 14)
        self.rect(15, y, w, h, "F")
        # Blue left accent
        self.set_fill_color(*COBALT_BRIGHT)
        self.rect(15, y, 2.5, h, "F")
        # Icon
        self.set_xy(20, y + 2)
        self.set_font("Helvetica", "B", 9)
        self.set_text_color(*COBALT_MID)
        self.cell(5, 5, "i")
        # Text
        self.set_xy(25, y + 2)
        self.set_font("Helvetica", "I", 9)
        self.set_text_color(40, 60, 90)
        self.multi_cell(155, 5, text)
        self.set_y(y + h + 3)

    def warning_box(self, text):
        """Orange warning box."""
        self.ln(2)
        y = self.get_y()
        self.set_fill_color(255, 243, 224)
        w = 170
        self.set_font("Helvetica", "", 9)
        nb_lines = len(text) / 75 + text.count('\n') + 1
        h = max(nb_lines * 5 + 6, 14)
        self.rect(15, y, w, h, "F")
        self.set_fill_color(*ORANGE)
        self.rect(15, y, 2.5, h, "F")
        self.set_xy(20, y + 2)
        self.set_font("Helvetica", "B", 9)
        self.set_text_color(*ORANGE)
        self.cell(5, 5, "!")
        self.set_xy(25, y + 2)
        self.set_font("Helvetica", "", 9)
        self.set_text_color(100, 60, 0)
        self.multi_cell(155, 5, text)
        self.set_y(y + h + 3)

    def numbered_step(self, number, text, bold_part=""):
        """Numbered instruction step."""
        y = self.get_y()
        if y > 270:
            self.add_page()
            y = self.get_y()
        # Number circle
        self.set_fill_color(*COBALT_BRIGHT)
        self.set_text_color(*WHITE)
        self.set_font("Helvetica", "B", 8)
        cx = 15
        self.ellipse(cx, y + 0.5, 5.5, 5.5, "F")
        self.set_xy(cx, y + 0.5)
        self.cell(5.5, 5.5, str(number), align="C")
        # Text
        self.set_xy(23, y)
        self.set_text_color(*BLACK)
        if bold_part:
            self.set_font("Helvetica", "B", 10)
            w_bold = self.get_string_width(bold_part) + 1
            self.cell(w_bold, 6, bold_part)
            self.set_font("Helvetica", "", 10)
            self.multi_cell(0, 6, text)
        else:
            self.set_font("Helvetica", "", 10)
            self.multi_cell(170, 6, text)
        self.ln(1)

    def voice_example(self, text):
        """Styled voice command example with quote marks."""
        y = self.get_y()
        if y > 272:
            self.add_page()
            y = self.get_y()
        self.set_fill_color(245, 247, 250)
        h = 7
        self.rect(20, y, 165, h, "F")
        # Left accent
        self.set_fill_color(*COBALT_MID)
        self.rect(20, y, 1.5, h, "F")
        self.set_xy(25, y + 0.5)
        self.set_font("Helvetica", "I", 9.5)
        self.set_text_color(*COBALT_DARK)
        self.cell(0, 6, f'"{text}"')
        self.ln(h + 1.5)

    def table_row(self, cols, widths, header=False, fill_color=None):
        """Single table row."""
        y = self.get_y()
        if y > 270:
            self.add_page()
            y = self.get_y()
        max_h = 7
        if header:
            self.set_fill_color(*COBALT_DARK)
            self.set_text_color(*WHITE)
            self.set_font("Helvetica", "B", 9)
        else:
            if fill_color:
                self.set_fill_color(*fill_color)
            else:
                self.set_fill_color(*WHITE)
            self.set_text_color(*BLACK)
            self.set_font("Helvetica", "", 9)

        x = 15
        for i, (col, w) in enumerate(zip(cols, widths)):
            self.set_xy(x, y)
            self.cell(w, max_h, f" {col}", border=0, fill=True)
            x += w
        self.ln(max_h)

    def category_badge(self, name, color, description):
        """Colored category badge + description."""
        y = self.get_y()
        if y > 265:
            self.add_page()
            y = self.get_y()
        # Badge
        self.set_fill_color(*color)
        self.set_text_color(*WHITE)
        self.set_font("Helvetica", "B", 9)
        bw = self.get_string_width(name) + 8
        self.set_xy(15, y)
        self.cell(bw, 7, f" {name} ", fill=True)
        # Description
        self.set_xy(15 + bw + 3, y)
        self.set_font("Helvetica", "", 10)
        self.set_text_color(*BLACK)
        self.cell(0, 7, description)
        self.ln(10)


# =============================================================================
# DOCUMENT 1 : GUIDE DE PRISE EN MAIN
# =============================================================================
def generate_guide():
    pdf = CobaltPDF("Guide de prise en main")
    pdf.alias_nb_pages()

    # --- COVER ---
    pdf.cover_page("Guide de prise en main", "Tout ce qu'il faut savoir pour installer\net configurer Cobalt Task en 10 minutes")

    # --- ETAPE 1 ---
    pdf.add_page()
    pdf.section_title("1", "Installer l'application")

    pdf.body_text("Tu as recu un fichier cobalt-task.apk. C'est le fichier d'installation de l'application. Comme elle n'est pas encore sur le Play Store, il faut autoriser l'installation manuellement.")

    pdf.sub_section("Autoriser les sources inconnues")
    pdf.numbered_step(1, "Ouvre le fichier APK (depuis Telegram, Drive, ou la ou tu l'as recu)")
    pdf.numbered_step(2, 'Android affiche un message "Installation bloquee" ou "Source inconnue"')
    pdf.numbered_step(3, 'Appuie sur "Parametres"')
    pdf.numbered_step(4, 'Active l\'option "Autoriser cette source"')
    pdf.numbered_step(5, 'Reviens en arriere et appuie sur "Installer"')

    pdf.tip_box("C'est normal ! C'est juste parce que l'app n'est pas encore sur le Play Store. Tu peux desactiver cette option apres l'installation.")

    pdf.sub_section("Installer et ouvrir")
    pdf.numbered_step(1, 'Appuie sur "Installer"')
    pdf.numbered_step(2, "Attends quelques secondes")
    pdf.numbered_step(3, 'Appuie sur "Ouvrir"')

    pdf.body_text("L'application est installee !")

    # --- ETAPE 2 ---
    pdf.section_title("2", "Accepter les permissions")

    pdf.body_text("Au premier lancement, l'app te demande plusieurs autorisations. Accepte-les toutes, elles sont necessaires :")

    pdf.ln(2)
    widths = [50, 130]
    pdf.table_row(["Permission", "A quoi ca sert"], widths, header=True)
    pdf.table_row(["Microphone", "Enregistrer ta voix (le coeur de l'app !)"], widths, fill_color=LIGHT_GRAY)
    pdf.table_row(["Contacts", "Trouver les destinataires de tes SMS / appels"], widths, fill_color=WHITE)
    pdf.table_row(["Telephone", "Passer des appels directement"], widths, fill_color=LIGHT_GRAY)
    pdf.table_row(["SMS", "Envoyer des SMS par la voix"], widths, fill_color=WHITE)
    pdf.table_row(["Localisation", "Bluetooth + navigation GPS"], widths, fill_color=LIGHT_GRAY)
    pdf.table_row(["Bluetooth", "Se connecter au bracelet Cobalt"], widths, fill_color=WHITE)
    pdf.ln(2)

    pdf.tip_box("Si tu refuses une permission par erreur, tu peux la reactiver dans :\nParametres Android > Applications > Cobalt Task > Autorisations")

    pdf.sub_section("Permissions speciales (optionnelles)")
    pdf.body_text("L'app peut aussi te proposer :")
    pdf.numbered_step(1, "Superposition d'ecran : utiliser Cobalt meme ecran verrouille")
    pdf.numbered_step(2, "Acces aux notifications : repondre aux messages via la bonne app")
    pdf.numbered_step(3, "Assistant par defaut : activer Cobalt avec un appui long sur Power")
    pdf.body_text("Pour chacune, l'app t'explique ce qu'elle fait. Accepte celles qui t'interessent.")

    # --- ETAPE 3 ---
    pdf.add_page()
    pdf.section_title("3", "Connecter ton compte Google")

    pdf.body_text("C'est l'etape la plus importante. Avec Google, tes notes, taches et evenements se synchronisent automatiquement avec Google Tasks, Calendar et Contacts.")

    pdf.sub_section("Se connecter")
    pdf.numbered_step(1, "Sur l'ecran principal, regarde en haut a droite : icone nuage grise")
    pdf.numbered_step(2, "Appuie dessus")
    pdf.numbered_step(3, 'Un menu s\'ouvre en bas : appuie sur "Connecter Google"')
    pdf.numbered_step(4, "Choisis ton compte Google (ou connecte-toi)")

    pdf.ln(2)
    pdf.warning_box('Google affiche un avertissement "Cette application n\'a pas ete validee".\nC\'est NORMAL, l\'app est en phase de test !')

    pdf.ln(2)
    pdf.sub_section("Passer l'avertissement Google")
    pdf.numbered_step(1, 'Appuie sur "Avance" (ou "Advanced") en bas a gauche')
    pdf.numbered_step(2, 'Appuie sur "Acceder a Cobalt Task (non securise)"')
    pdf.numbered_step(3, 'Google demande les autorisations : appuie sur "Tout autoriser"')
    pdf.numbered_step(4, 'Appuie sur "Continuer"')

    pdf.tip_box("L'icone nuage passe du gris au bleu : tu es connecte !\nEn appuyant dessus, tu verras ton nom et ton email.")

    pdf.ln(2)
    pdf.warning_box("Le token Google expire tous les 7 jours en mode test. Si l'app te redemande de te connecter, c'est normal : refais simplement cette etape.")

    # --- ETAPE 4 ---
    pdf.section_title("4", "Connecter Spotify (optionnel)")

    pdf.body_text("Si tu veux controler ta musique par la voix (lecture, pause, recherche de chanson...), connecte ton compte Spotify.")

    pdf.sub_section("Ce qu'il te faut")
    pdf.body_text("- L'app Spotify installee sur ton telephone\n- Un compte Spotify (gratuit ou premium)")

    pdf.warning_box("Ton compte Spotify doit etre ajoute a la liste des testeurs. Si la connexion echoue, demande-moi de t'ajouter !")

    pdf.sub_section("Se connecter")
    pdf.numbered_step(1, "Repere l'icone note de musique en haut a droite (a cote du nuage)")
    pdf.numbered_step(2, "Appuie dessus")
    pdf.numbered_step(3, 'Appuie sur "Connecter Spotify"')
    pdf.numbered_step(4, "Spotify s'ouvre dans le navigateur : connecte-toi")
    pdf.numbered_step(5, "Autorise l'acces")
    pdf.numbered_step(6, "Tu es redirige automatiquement vers Cobalt Task")

    pdf.tip_box("L'icone note de musique passe au vert : Spotify est connecte !")

    # --- ETAPE 5 ---
    pdf.add_page()
    pdf.section_title("5", "Premiers pas")

    pdf.sub_section("Enregistrer ton premier memo vocal")
    pdf.numbered_step(1, "Appui long sur le gros bouton rouge micro en bas de l'ecran")
    pdf.numbered_step(2, "Parle naturellement en francais")
    pdf.numbered_step(3, "Relache le bouton quand tu as fini")

    pdf.body_text("L'app va automatiquement :\n- Transcrire ta voix en texte\n- Comprendre ce que tu veux faire\n- Classer ta note dans la bonne categorie\n- Synchroniser avec Google")

    pdf.sub_section("Lire et gerer tes notes")
    pdf.body_text("- Appuie sur une carte pour la deplier (texte complet + lecture audio)\n- Glisse vers la gauche pour supprimer")

    pdf.sub_section("Les categories (automatiques)")
    pdf.body_text("L'app decide toute seule dans quelle categorie ranger ta note :")
    pdf.ln(2)
    pdf.category_badge("Tache", (74, 144, 217), '"Faut que j\'appelle le plombier"')
    pdf.category_badge("Courses", CYAN, '"Acheter du lait, des oeufs et du pain"')
    pdf.category_badge("Evenement", (52, 168, 83), '"Rendez-vous vendredi 14h"')
    pdf.category_badge("Contact", PURPLE, '"Marie, 06 12 34 56 78"')
    pdf.category_badge("Memo", ORANGE, '"Idee : refaire la deco du salon"')

    # --- DEPANNAGE ---
    pdf.section_title("", "Depannage")

    pdf.sub_section('"L\'app dit que le contact n\'est pas confirme"')
    pdf.body_text("La premiere fois que tu envoies un message a quelqu'un, Cobalt te demande de confirmer le bon contact. Ouvre l'app, valide le contact, et les prochains messages partiront automatiquement.")

    pdf.sub_section('"Google me redemande de me connecter"')
    pdf.body_text("En mode test, la connexion expire tous les 7 jours. Refais simplement l'etape 3.")

    pdf.sub_section('"Spotify ne repond pas"')
    pdf.body_text("Verifie que Spotify est ouvert en arriere-plan. L'app controle Spotify a distance mais il doit etre actif.")

    pdf.sub_section('"L\'app ne capte pas ma voix"')
    pdf.body_text("- Verifie la permission Microphone (Parametres > Applis > Cobalt Task)\n- Essaie dans un endroit plus calme\n- Parle a volume normal, pas besoin de crier")

    pdf.sub_section('"Je n\'arrive pas a installer l\'APK"')
    pdf.body_text("Verifie que tu as bien autorise les sources inconnues (etape 1). Sur Samsung : Parametres > Biometrie et securite > Installation applis inconnues.")

    # --- RESUME ---
    pdf.add_page()
    pdf.section_title("", "En resume")

    pdf.ln(4)
    widths = [15, 90, 25]
    pdf.table_row(["#", "Quoi faire", "Temps"], widths, header=True)
    pdf.table_row(["1", "Installer l'APK", "2 min"], widths, fill_color=LIGHT_GRAY)
    pdf.table_row(["2", "Accepter les permissions", "1 min"], widths, fill_color=WHITE)
    pdf.table_row(["3", "Connecter Google", "3 min"], widths, fill_color=LIGHT_GRAY)
    pdf.table_row(["4", "Connecter Spotify (optionnel)", "2 min"], widths, fill_color=WHITE)
    pdf.table_row(["5", "Parler dans le micro !", "0 min"], widths, fill_color=LIGHT_GRAY)

    pdf.ln(8)
    pdf.set_font("Helvetica", "B", 14)
    pdf.set_text_color(*COBALT_DARK)
    pdf.cell(0, 10, "C'est tout ! Amuse-toi bien avec Cobalt Task.", align="C", new_x="LMARGIN", new_y="NEXT")
    pdf.ln(3)
    pdf.set_font("Helvetica", "", 11)
    pdf.set_text_color(*GRAY)
    pdf.cell(0, 8, "Si tu as un bug ou une question, contacte-moi directement.", align="C")

    # --- SAVE ---
    path = os.path.join(OUTPUT_DIR, "Cobalt_Task_-_Guide_de_prise_en_main.pdf")
    pdf.output(path)
    print(f"OK: {path}")
    return path


# =============================================================================
# DOCUMENT 2 : FICHE FONCTIONNALITES
# =============================================================================
def generate_features():
    pdf = CobaltPDF("Fonctionnalites")
    pdf.alias_nb_pages()

    # --- COVER ---
    pdf.cover_page("Fonctionnalites", "Tout ce que Cobalt Task sait faire")

    # === NOTES AUTO-CLASSEES ===
    pdf.add_page()
    pdf.section_title("", "Tes notes, classees automatiquement")
    pdf.body_text("Dicte n'importe quoi, Cobalt comprend tout seul s'il s'agit d'une tache, de courses, d'un rendez-vous, d'un contact ou d'un simple memo.")

    # -- Taches --
    pdf.sub_section("Taches")
    pdf.body_text("Dis ce que tu dois faire, Cobalt le note et le synchronise avec Google Tasks.")
    pdf.voice_example("Faut que j'appelle le plombier")
    pdf.voice_example("Envoyer le dossier a Marc avant mardi")
    pdf.voice_example("N'oublie pas de faire des pompes demain")
    pdf.category_badge("Tache", (74, 144, 217), "Synchronise avec Google Tasks")

    # -- Courses --
    pdf.sub_section("Liste de courses")
    pdf.body_text("Dis ce que tu dois acheter. Cobalt reconnait les produits et cree ta liste automatiquement. Plus de 150 produits courants reconnus.")
    pdf.voice_example("Acheter du lait, des oeufs et du pain")
    pdf.voice_example("Il me faut de la farine et du beurre")
    pdf.voice_example("J'ai besoin de piles et de scotch")
    pdf.category_badge("Courses", CYAN, "Chaque article apparait dans Google Tasks \"Courses\"")

    # -- Evenements --
    pdf.sub_section("Evenements et rendez-vous")
    pdf.body_text("Dis ou tu dois etre et quand, Cobalt cree l'evenement dans ton agenda.")
    pdf.voice_example("Rendez-vous chez le medecin vendredi 14h")
    pdf.voice_example("Reunion mardi 10h en salle B")
    pdf.voice_example("Cafe avec Marie samedi 15h au bistro")
    pdf.category_badge("Evenement", (52, 168, 83), "Cree automatiquement dans Google Calendar")

    # -- Contacts --
    pdf.sub_section("Contacts")
    pdf.body_text("Dicte un nom et un numero, Cobalt l'enregistre dans tes contacts Google.")
    pdf.voice_example("Marie, 06 12 34 56 78")
    pdf.voice_example("Pierre Dupont, email pierre@work.com, digicode 4321")
    pdf.category_badge("Contact", PURPLE, "Ajoute dans Google Contacts")

    # -- Memos --
    pdf.sub_section("Memos libres")
    pdf.body_text("Tout le reste : idees, reflexions, notes rapides.")
    pdf.voice_example("Idee : utiliser du bois pour la terrasse")
    pdf.voice_example("Penser a la reunion de demain")
    pdf.category_badge("Memo", ORANGE, "Synchronise avec Google Tasks \"Memos\"")

    # === MESSAGERIE ===
    pdf.add_page()
    pdf.section_title("", "Envoyer des messages par la voix")
    pdf.body_text("Dis a qui et quoi envoyer. Cobalt gere SMS, WhatsApp, Telegram, Signal et Messenger.")

    pdf.sub_section("SMS")
    pdf.voice_example("Envoie un SMS a Pierre : je suis en route")
    pdf.voice_example("Text Marie : ca va ?")

    pdf.sub_section("WhatsApp")
    pdf.voice_example("WhatsApp a Sarah : t'es libre ce soir ?")

    pdf.sub_section("Telegram / Signal / Messenger")
    pdf.voice_example("Telegram a Claire : libre demain ?")
    pdf.voice_example("Message Signal a Tom : appelle-moi")

    pdf.sub_section("Message intelligent")
    pdf.body_text("Si tu ne precises pas l'app, Cobalt choisit automatiquement la bonne en fonction de tes habitudes avec ce contact.")
    pdf.voice_example("Envoie un message a Paul : a plus !")

    pdf.tip_box("La premiere fois que tu envoies un message a quelqu'un, Cobalt te demande de confirmer le bon contact. Ensuite, ca part automatiquement.")

    # === APPELS ===
    pdf.section_title("", "Passer des appels")
    pdf.body_text("L'appel se lance directement, sans toucher le telephone.")
    pdf.voice_example("Appelle Maman")
    pdf.voice_example("Passe un appel a Marie")

    # === ALARMES / TIMERS ===
    pdf.section_title("", "Alarmes et minuteurs")

    pdf.sub_section("Alarmes")
    pdf.voice_example("Mets une alarme pour 7h du matin")
    pdf.voice_example("Reveille-moi a 6h")
    pdf.body_text("Cree une alarme dans l'horloge de ton telephone.")

    pdf.sub_section("Minuteurs")
    pdf.voice_example("Minuteur 5 minutes")
    pdf.voice_example("Timer 10 minutes pour les pates")
    pdf.body_text("Lance un compte a rebours directement.")

    # === MUSIQUE ===
    pdf.add_page()
    pdf.section_title("", "Controler la musique")

    pdf.sub_section("Avec Spotify connecte")
    pdf.body_text("Cobalt cherche sur Spotify et lance la lecture. Fonctionne meme ecran eteint.")
    pdf.voice_example("Joue du jazz")
    pdf.voice_example("Mets du Dua Lipa")
    pdf.voice_example("Cherche les Beatles")

    pdf.sub_section("Commandes universelles")
    pdf.body_text("Ces commandes marchent avec n'importe quelle app de musique (Spotify, YouTube Music, Deezer...) :")
    pdf.voice_example("Pause")
    pdf.voice_example("Piste suivante")
    pdf.voice_example("Piste precedente")
    pdf.voice_example("Arrete la musique")

    # === NAVIGATION ===
    pdf.section_title("", "Navigation GPS")
    pdf.body_text("Cobalt calcule l'itineraire, te lit un resume vocal du trajet, puis ouvre Google Maps.")
    pdf.voice_example("Navigue vers la gare Saint-Lazare")
    pdf.voice_example("Itineraire a pied vers le parc")
    pdf.voice_example("Route en velo vers le lycee")
    pdf.voice_example("Transports en commun vers la fac")

    pdf.ln(3)
    widths = [60, 60]
    pdf.table_row(["Tu dis...", "Mode"], widths, header=True)
    pdf.table_row(["(rien de special)", "Voiture"], widths, fill_color=LIGHT_GRAY)
    pdf.table_row(['"a pied"', "Marche"], widths, fill_color=WHITE)
    pdf.table_row(['"en velo"', "Velo"], widths, fill_color=LIGHT_GRAY)
    pdf.table_row(['"en transport / metro"', "Transports en commun"], widths, fill_color=WHITE)

    # === CONTROLES SYSTEME ===
    pdf.section_title("", "Controles du telephone")

    pdf.sub_section("Volume")
    pdf.voice_example("Augmente le volume")
    pdf.voice_example("Baisse le volume")
    pdf.voice_example("Coupe le son")
    pdf.voice_example("Volume a 50%")

    pdf.sub_section("Modes sonores")
    pdf.voice_example("Mode silencieux")
    pdf.voice_example("Mets le vibreur")
    pdf.voice_example("Mode normal")

    pdf.sub_section("Lampe torche")
    pdf.voice_example("Active la lampe torche")
    pdf.voice_example("Eteins la lampe")

    pdf.sub_section("Autres")
    pdf.body_text("- \"Active le Wi-Fi\" (ouvre les parametres Wi-Fi)\n- \"Mode avion\" (ouvre les parametres)\n- \"Ne pas deranger\" (ouvre les parametres)")

    # === OUVRIR DES APPS ===
    pdf.add_page()
    pdf.section_title("", "Ouvrir des applications")
    pdf.voice_example("Ouvre Gmail")
    pdf.voice_example("Lance Chrome")
    pdf.voice_example("Ouvre l'appareil photo")

    # === ECRAN VERROUILLE ===
    pdf.section_title("", "Ca marche aussi ecran verrouille")
    pdf.body_text("Cobalt est concu pour fonctionner sans meme regarder ton telephone :")

    pdf.numbered_step(1, "Bouton Power (appui long) : active l'assistant et commence a enregistrer")
    pdf.numbered_step(2, "Notification permanente : un bouton micro permet de lancer un enregistrement a tout moment")
    pdf.numbered_step(3, "Confirmation vocale : apres chaque action, Cobalt te confirme a voix haute ce qu'il a fait")

    pdf.tip_box("Tu peux garder ton telephone dans ta poche et tout faire a la voix.")

    # === BRACELET ===
    pdf.section_title("", "Bracelet connecte")
    pdf.body_text("Si tu as le bracelet Cobalt Voice :")
    pdf.numbered_step(1, "Un appui sur le bouton du bracelet : commence a enregistrer")
    pdf.numbered_step(2, "Un autre appui : arrete l'enregistrement")
    pdf.body_text("L'audio est transmis en Bluetooth au telephone. Le niveau de batterie du bracelet s'affiche dans l'app.")

    # === SYNCHRO GOOGLE ===
    pdf.section_title("", "Synchronisation Google")
    pdf.body_text("Tout ce que tu dictes se retrouve automatiquement dans tes services Google :")
    pdf.ln(2)
    widths = [60, 90]
    pdf.table_row(["Ce que tu dis", "Ou ca arrive"], widths, header=True)
    pdf.table_row(["Une tache", "Google Tasks (Mes taches)"], widths, fill_color=LIGHT_GRAY)
    pdf.table_row(["Des courses", 'Google Tasks (liste "Courses")'], widths, fill_color=WHITE)
    pdf.table_row(["Un rendez-vous", "Google Calendar"], widths, fill_color=LIGHT_GRAY)
    pdf.table_row(["Un contact", "Google Contacts"], widths, fill_color=WHITE)
    pdf.table_row(["Un memo", 'Google Tasks (liste "Memos")'], widths, fill_color=LIGHT_GRAY)

    pdf.ln(4)
    pdf.body_text("Tu retrouves tout sur ton ordinateur, ta tablette, ou n'importe quel appareil connecte a ton compte Google.")

    # === HORS CONNEXION ===
    pdf.section_title("", "Fonctionne hors connexion")
    pdf.body_text("Meme sans internet, tu peux :")
    pdf.body_text("- Enregistrer des memos vocaux\n- Passer des appels et envoyer des SMS\n- Creer des alarmes et minuteurs\n- Controler le volume, la lampe torche\n- Lancer des applications")
    pdf.tip_box("Quand tu retrouves une connexion, les notes en attente se synchronisent automatiquement avec Google.")

    # === RESUME ===
    pdf.add_page()
    pdf.section_title("", "En un coup d'oeil")
    pdf.ln(4)
    widths = [70, 110]
    pdf.table_row(["Fonction", "Comment"], widths, header=True)
    pdf.table_row(["Enregistrer", "Appui long sur le bouton micro rouge"], widths, fill_color=LIGHT_GRAY)
    pdf.table_row(["Voir une note", "Appuyer sur la carte"], widths, fill_color=WHITE)
    pdf.table_row(["Supprimer une note", "Glisser la carte vers la gauche"], widths, fill_color=LIGHT_GRAY)
    pdf.table_row(["Connecter Google", "Icone nuage (en haut a droite)"], widths, fill_color=WHITE)
    pdf.table_row(["Connecter Spotify", "Icone musique (en haut a droite)"], widths, fill_color=LIGHT_GRAY)
    pdf.table_row(["Connecter le bracelet", "Icone Bluetooth (en haut a droite)"], widths, fill_color=WHITE)

    # --- SAVE ---
    path = os.path.join(OUTPUT_DIR, "Cobalt_Task_-_Fonctionnalites.pdf")
    pdf.output(path)
    print(f"OK: {path}")
    return path


if __name__ == "__main__":
    print("Generation des PDFs Cobalt Task...")
    print()
    generate_guide()
    generate_features()
    print()
    print("Termine !")
