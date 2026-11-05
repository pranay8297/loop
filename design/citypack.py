"""Builds design/citypack.json: one landmark per city, drawn as a single-line SVG path.

Paths live in a 200 x 60 box with the ground at y = 58. Only absolute M L H V C Q Z
commands are used, so the iPhone app can draw them with a tiny parser.
"""
import json, math

def circle(cx, cy, r):
    k = 0.5523 * r
    return (f"M{cx - r:g} {cy:g}C{cx - r:g} {cy - k:g} {cx - k:g} {cy - r:g} {cx:g} {cy - r:g}"
            f"C{cx + k:g} {cy - r:g} {cx + r:g} {cy - k:g} {cx + r:g} {cy:g}"
            f"C{cx + r:g} {cy + k:g} {cx + k:g} {cy + r:g} {cx:g} {cy + r:g}"
            f"C{cx - k:g} {cy + r:g} {cx - r:g} {cy + k:g} {cx - r:g} {cy:g}Z")

def r1(v):
    return f"{round(v, 2):g}"

def colosseum():
    s = "M60 58V27C60 23 140 23 140 27V58M60 37H140M60 47H140"
    x = 64.5
    while x < 134:
        s += f"M{r1(x)} 58V53C{r1(x)} 50 {r1(x + 5)} 50 {r1(x + 5)} 53V58"
        s += f"M{r1(x)} 47V43C{r1(x)} 40.5 {r1(x + 5)} 40.5 {r1(x + 5)} 43V47"
        x += 8.6
    return s

def parthenon():
    s = "M58 58H142M60 36H140M60 32H140M60 32L100 20L140 32M60 36V32M140 36V32"
    for i in range(9):
        x = 63 + i * 9.25
        s += f"M{r1(x)} 58V36"
    return s

def taipei101():
    s = "M93 58V47H107V58"
    y = 47
    for _ in range(7):
        s += f"M94 {r1(y)}L92 {r1(y - 4.6)}H108L106 {r1(y)}"
        y -= 4.6
    s += f"M96.5 {r1(y)}V{r1(y - 5)}H103.5V{r1(y)}M100 {r1(y - 5)}V1"
    return s

def vidhana():
    s = "M48 58V40H152V58M86 40V31H114V40M88 31C88 21 112 21 112 31M100 21V15"
    for x in (56, 64, 72, 128, 136, 144):
        s += f"M{x} 58V45"
    return s

def gopuram():
    s, w, y, h = "", 16, 58, 7.5
    for i in range(6):
        nw = w - 2.4
        s += f"M{r1(100 - w)} {r1(y)}L{r1(100 - nw)} {r1(y - h)}H{r1(100 + nw)}L{r1(100 + w)} {r1(y)}"
        w, y, h = nw, y - h, h * 0.92
    s += f"M{r1(100 - w)} {r1(y)}C{r1(100 - w)} {r1(y - 4)} {r1(100 + w)} {r1(y - 4)} {r1(100 + w)} {r1(y)}M100 {r1(y - 3)}V{r1(y - 6)}"
    return s

def petronas():
    def tower(c):
        return (f"M{c - 7} 58V26H{c - 5}V18H{c - 3}V12H{c - 1.5}V6L{c} 1L{c + 1.5} 6V12H{c + 3}V18H{c + 5}V26H{c + 7}V58")
    return tower(85) + tower(115) + "M92 34H108"

def sagrada():
    s = "M68 58V44H132V58"
    for cx, top, base in ((78, 12, 30), (89, 5, 24), (100, 1, 22), (111, 5, 24), (122, 12, 30)):
        s += f"M{cx - 4} 44V{base}L{cx} {top}L{cx + 4} {base}V44"
    return s

def amsterdam():
    return ("M56 58V32L60 28V24H66V28L70 32V58M70 58V28L74 24V20H80V24L84 28V58"
            "M84 58V34L92 25L100 34V58M100 58V26L104 22V17H110V22L114 26V58M114 58V31L118 27V24H124V27L128 31V58"
            "M128 58V36L135 29L142 36V58")

def howrah():
    return ("M12 46H188M60 58V12M66 58V12M134 58V12M140 58V12M60 12H66M134 12H140"
            "M12 46L60 14M66 14L100 34L134 14M140 14L188 46M66 46L100 34L134 46M60 30H66M134 30H140")

def golden_gate():
    return ("M6 48H194M60 58V12M66 58V12M134 58V12M140 58V12M60 20H66M60 33H66M134 20H140M134 33H140"
            "M6 30Q34 46 63 13Q100 46 137 13Q166 46 194 30")

def palms():
    def palm(x, h, lean):
        tx = x + lean
        ty = 58 - h
        return (f"M{x} 58C{x} {r1(58 - h * 0.45)} {r1(x + lean * 0.4)} {r1(58 - h * 0.8)} {r1(tx)} {r1(ty)}"
                f"M{r1(tx)} {r1(ty)}C{r1(tx - 6)} {r1(ty - 4)} {r1(tx - 12)} {r1(ty - 3)} {r1(tx - 16)} {r1(ty)}"
                f"M{r1(tx)} {r1(ty)}C{r1(tx - 4)} {r1(ty - 7)} {r1(tx - 8)} {r1(ty - 9)} {r1(tx - 13)} {r1(ty - 9)}"
                f"M{r1(tx)} {r1(ty)}C{r1(tx + 4)} {r1(ty - 7)} {r1(tx + 9)} {r1(ty - 8)} {r1(tx + 13)} {r1(ty - 6)}"
                f"M{r1(tx)} {r1(ty)}C{r1(tx + 6)} {r1(ty - 3)} {r1(tx + 11)} {r1(ty - 1)} {r1(tx + 14)} {r1(ty + 3)}")
    return palm(84, 42, 4) + palm(104, 50, -3) + palm(122, 34, 3)

def temple_heaven():
    return ("M76 58V54H124V58M86 54V46H114V54M80 46H120L114 40H86ZM88 40V35H112V40"
            "M84 35H116L110 29H90ZM92 29V25H108V29M88 25H112L104 17H96ZM100 17V11")

def wat_arun():
    def prang(c, h, w):
        top = 58 - h
        return (f"M{c - w} 58L{r1(c - w * 0.66)} {r1(58 - h * 0.35)}L{r1(c - w * 0.4)} {r1(58 - h * 0.7)}"
                f"L{c} {r1(top)}L{r1(c + w * 0.4)} {r1(58 - h * 0.7)}L{r1(c + w * 0.66)} {r1(58 - h * 0.35)}L{c + w} 58"
                f"M{r1(c - w * 0.8)} {r1(58 - h * 0.2)}H{r1(c + w * 0.8)}M{r1(c - w * 0.53)} {r1(58 - h * 0.5)}H{r1(c + w * 0.53)}")
    return prang(100, 56, 13) + prang(74, 24, 7) + prang(126, 24, 7)

def oriental_pearl():
    return ("M92 58L96.5 45M108 58L103.5 45M98 33V24.5M102 33V24.5M100 15.5V2" + circle(100, 40, 7) + circle(100, 20, 4.5)
            + "M124 58C124 34 125 18 129 7M135 58C135 34 134 18 129 7")

def n_seoul():
    return "M36 58C68 46 88 40 100 40C112 40 132 46 164 58M99 40V22M101 40V22M95 22H105V17H95ZM100 17V7"

def fernsehturm():
    return "M98 58V30M102 58V30" + circle(100, 24, 6) + "M98.6 18V10M101.4 18V10M100 10V1"

C = []
def add(key, name, local, fs, country, lat, lon, landmark, sky, radius=40):
    C.append(dict(key=key, name=name, local=local, fontScale=fs, country=country,
                  lat=lat, lon=lon, radiusKm=radius, landmark=landmark, path=sky))

# The first eight (as published on the concept page). S commands turned into C.
add("dxb", "Dubai", "دبي", 21, "United Arab Emirates", 25.20, 55.27, "Burj Khalifa",
    "M91 58V46H93V36H95V26H96.6V17H97.8V9H99L100 1L101 9H102.2V17H103.4V26H105V36H107V46H109V58M62 58V48H72V58M128 58V44H136V58M140 58V51H150V58", 45)
add("auh", "Abu Dhabi", "أبوظبي", 18, "United Arab Emirates", 24.45, 54.38, "Sheikh Zayed Grand Mosque",
    "M64 58V46H136V58M86 46C86 32 95 27 100 25C105 27 114 32 114 46M100 25V19M70 46C70 41 74 38.5 77 38.5C80 38.5 84 41 84 46M116 46C116 41 120 38.5 123 38.5C126 38.5 130 41 130 46M55 58V18H60V58M55 18L57.5 11L60 18M140 58V18H145V58M140 18L142.5 11L145 18", 45)
add("lon", "London", "London", 19, "United Kingdom", 51.51, -0.13, "Elizabeth Tower",
    "M94 58V26H106V58M93 26H107M95 26V18H105V26M95 18L100 6L105 18M100 6V1M106 46H154V58M112 46V42M120 46V42M128 46V42M136 46V42M144 46V42M152 46V42", 35)
add("par", "Paris", "Paris", 21, "France", 48.86, 2.35, "Eiffel Tower",
    "M84 58C90 47 95 30 97.6 8M116 58C110 47 105 30 102.4 8M89 58Q100 46 111 58M88.4 47H111.6M93.6 34H106.4M97.6 8H102.4V4H97.6ZM100 4V0.5", 25)
add("nyc", "New York", "New York", 16, "United States", 40.71, -74.01, "Empire State Building",
    "M88 58V30H90V24H93V18H95.5V12H97.5V8H99.3L100 1L100.7 8H102.5V12H104.5V18H107V24H110V30H112V58M68 58V40H80V58M120 58V36H130V58M134 58V46H142V58", 35)
add("tyo", "Tokyo", "東京", 18, "Japan", 35.68, 139.69, "Tokyo Tower",
    "M86 58L97 10M114 58L103 10M90 58Q100 50 110 58M88 44H112V40H88ZM95.5 24H104.5V21H95.5ZM97 10H103M100 10V0.5", 45)
add("sin", "Singapore", "Singapura", 15, "Singapore", 1.29, 103.85, "Marina Bay Sands",
    "M74 58L77 23.5H85L86.5 58M94 58L97 23.5H105L106.5 58M114 58L117 23.5H125L126.5 58M70 23.5H144M144 23.5C143 21.6 141 20.6 138 20.6H73C71.6 21.4 70.6 22.4 70 23.5", 30)
add("hyd", "Hyderabad", "హైదరాబాద్", 12, "India", 17.39, 78.49, "Charminar",
    "M83 58V30H117V58M92 58V44C92 37 108 37 108 44V58M86 30V24H114V30M77 58V12H83V30M77 12C77 7 83 7 83 12M80 7.5V3M123 58V12H117V30M117 12C117 7 123 7 123 12M120 7.5V3", 40)

# The rest of the launch pack.
add("doh", "Doha", "الدوحة", 17, "Qatar", 25.29, 51.53, "Doha Tower",
    "M94 58V15C94 9 97 6 100 5C103 6 106 9 106 15V58M100 5V1M70 58V46H82V58M116 58V40H124V58M128 58V49H140V58", 30)
add("ruh", "Riyadh", "الرياض", 17, "Saudi Arabia", 24.71, 46.68, "Kingdom Centre",
    "M88 58L91 5Q100 27 109 5L112 58M93.6 16.5H106.4M66 58V46H78V58M122 58V42H132V58", 45)
add("ist", "Istanbul", "İstanbul", 15, "Türkiye", 41.01, 28.98, "Galata Tower",
    "M93 58V22H107V58M91.5 22H108.5M93 22L100 8L107 22M100 8V4M120 58V48C120 41 126 38 130 38C134 38 140 41 140 48V58M146 58V20H149V58M146 20L147.5 14L149 20M56 58V30H59V58M56 30L57.5 24L59 30", 45)
add("cai", "Cairo", "القاهرة", 17, "Egypt", 30.04, 31.24, "Pyramids of Giza",
    "M54 58L82 28L110 58M100 58L121 36L142 58M134 58L147 45L160 58", 45)
add("bom", "Mumbai", "मुंबई", 17, "India", 19.08, 72.88, "Gateway of India",
    "M76 58V30H124V58M91 58V42C91 33 109 33 109 42V58M76 30V25H83V30M117 30V25H124V30M86 30V24H114V30M95 24C95 19 105 19 105 24M80 58V46H86V58M114 58V46H120V58", 40)
add("del", "Delhi", "दिल्ली", 17, "India", 28.61, 77.21, "India Gate",
    "M82 58V18H118V58M92 58V34C92 25 108 25 108 34V58M80 18H120M86 18V12H114V18M94 12C94 7 106 7 106 12", 45)
add("blr", "Bengaluru", "ಬೆಂಗಳೂರು", 13, "India", 12.97, 77.59, "Vidhana Soudha", vidhana(), 40)
add("maa", "Chennai", "சென்னை", 14, "India", 13.08, 80.27, "Kapaleeshwarar Temple", gopuram(), 40)
add("ccu", "Kolkata", "কলকাতা", 15, "India", 22.57, 88.36, "Howrah Bridge", howrah(), 40)
add("ber", "Berlin", "Berlin", 21, "Germany", 52.52, 13.40, "Fernsehturm", fernsehturm(), 35)
add("ams", "Amsterdam", "Amsterdam", 13, "Netherlands", 52.37, 4.90, "Canal houses", amsterdam(), 25)
add("bcn", "Barcelona", "Barcelona", 14, "Spain", 41.39, 2.17, "Sagrada Família", sagrada(), 30)
add("mad", "Madrid", "Madrid", 19, "Spain", 40.42, -3.70, "Puerta de Alcalá",
    "M58 58V30H142V58M94 58V42C94 35 106 35 106 42V58M76 58V46C76 41 87 41 87 46V58M113 58V46C113 41 124 41 124 46V58M63 58V47H71V58M129 58V47H137V58M84 30V24H116V30M95 24V19H105V24", 35)
add("rom", "Rome", "Roma", 21, "Italy", 41.90, 12.50, "Colosseum", colosseum(), 35)
add("lis", "Lisbon", "Lisboa", 19, "Portugal", 38.72, -9.14, "Belém Tower",
    "M74 58V46H126V58M74 46V42H78V46M122 46V42H126V46M88 46V18H112V46M86 18H114M90 18V13H110V18M86 18V14H90M110 14H114V18M96 36V30C96 27 104 27 104 30V36", 30)
add("ath", "Athens", "Αθήνα", 17, "Greece", 37.98, 23.73, "Parthenon", parthenon(), 30)
add("yyz", "Toronto", "Toronto", 18, "Canada", 43.65, -79.38, "CN Tower",
    "M97 58L98.6 26M103 58L101.4 26M93 26H107M94 26C94 20.5 106 20.5 106 26M99 20.6V12M101 20.6V12M98 12H102M100 12V1M66 58V44H76V58M124 58V40H132V58", 40)
add("sfo", "San Francisco", "San Francisco", 11, "United States", 37.77, -122.42, "Golden Gate Bridge", golden_gate(), 35)
add("lax", "Los Angeles", "Los Angeles", 12, "United States", 34.05, -118.24, "Palm trees", palms(), 60)
add("chi", "Chicago", "Chicago", 18, "United States", 41.88, -87.63, "Willis Tower",
    "M84 58V30H88V18H93V8H107V14H112V26H116V58M96 8V1M104 8V2M64 58V42H74V58M124 58V36H134V58", 40)
add("mex", "Mexico City", "CDMX", 21, "Mexico", 19.43, -99.13, "Ángel de la Independencia",
    "M94 58V50H106V58M98 50V17H102V50M96 17H104M100 17V11M95 13.5L100 9.5L105 13.5", 45)
add("rio", "Rio de Janeiro", "Rio", 22, "Brazil", -22.91, -43.17, "Christ the Redeemer",
    "M28 58C60 50 80 30 100 26C120 30 140 50 172 58M100 26V15M92.5 17.5H107.5M100 15V12", 45)
add("bue", "Buenos Aires", "Buenos Aires", 11, "Argentina", -34.60, -58.38, "Obelisco",
    "M96.6 58L98.4 10L100 5L101.6 10L103.4 58M70 58V46H80V58M120 58V42H130V58", 40)
add("hkg", "Hong Kong", "香港", 18, "Hong Kong", 22.32, 114.17, "Victoria Harbour skyline",
    "M58 58V40H65V58M69 58V30H76V58M81 58V12L83.5 7H89.5L92 12V58M96 58V24H103V58M107 58V18L111 12L115 18V58M119 58V34H126V58M130 58V44H137V58M140 58V50H148V58", 35)
add("sel", "Seoul", "서울", 18, "South Korea", 37.57, 126.98, "N Seoul Tower", n_seoul(), 40)
add("sha", "Shanghai", "上海", 18, "China", 31.23, 121.47, "Oriental Pearl Tower", oriental_pearl(), 45)
add("pek", "Beijing", "北京", 18, "China", 39.90, 116.41, "Temple of Heaven", temple_heaven(), 45)
add("bkk", "Bangkok", "กรุงเทพฯ", 14, "Thailand", 13.76, 100.50, "Wat Arun", wat_arun(), 40)
add("kul", "Kuala Lumpur", "Kuala Lumpur", 11, "Malaysia", 3.14, 101.69, "Petronas Towers", petronas(), 35)
add("syd", "Sydney", "Sydney", 19, "Australia", -33.87, 151.21, "Sydney Opera House",
    "M68 58C70 40 79 30 91 26C87 36 87 48 89 58M88 58C92 42 100 32 112 28C108 38 108 50 110 58M108 58C112 46 118 38 128 36C125 44 125 52 126 58M64 58V55H134V58", 45)
add("cpt", "Cape Town", "Cape Town", 14, "South Africa", -33.92, 18.42, "Table Mountain",
    "M14 58C34 53 50 42 60 27H136C143 38 150 46 158 50C163 44 168 42 172 44C176 48 182 54 190 58", 40)
add("tpe", "Taipei", "臺北", 18, "Taiwan", 25.03, 121.57, "Taipei 101", taipei101(), 35)

assert len({c["key"] for c in C}) == len(C)
for c in C:
    bad = set(c["path"]) & set("aAsStT")
    assert not bad, (c["key"], bad)

out = {"version": 1, "box": [200, 60], "ground": 58, "cities": C}
json.dump(out, open(__file__.replace("citypack.py", "citypack.json"), "w"), ensure_ascii=False, indent=1)
print(len(C), "cities")
