"""Static reference data for the generator: voivodeships, cities, categories, product names."""

from dataclasses import dataclass


@dataclass(frozen=True)
class Region:
    code: str  # TERYT voivodeship code
    name: str
    purchasing_power_index: float  # 1.00 = national average (approx. GUS disposable income)
    population_m: float  # approx. population in millions (weights online customers)


REGIONS: tuple[Region, ...] = (
    Region("02", "dolnośląskie", 1.08, 2.88),
    Region("04", "kujawsko-pomorskie", 0.92, 2.01),
    Region("06", "lubelskie", 0.86, 2.02),
    Region("08", "lubuskie", 0.93, 0.98),
    Region("10", "łódzkie", 0.97, 2.39),
    Region("12", "małopolskie", 1.00, 3.43),
    Region("14", "mazowieckie", 1.25, 5.51),
    Region("16", "opolskie", 0.94, 0.95),
    Region("18", "podkarpackie", 0.84, 2.07),
    Region("20", "podlaskie", 0.88, 1.15),
    Region("22", "pomorskie", 1.05, 2.35),
    Region("24", "śląskie", 1.05, 4.32),
    Region("26", "świętokrzyskie", 0.87, 1.18),
    Region("28", "warmińsko-mazurskie", 0.86, 1.37),
    Region("30", "wielkopolskie", 1.03, 3.49),
    Region("32", "zachodniopomorskie", 0.96, 1.64),
)


@dataclass(frozen=True)
class City:
    code: str  # three-letter prefix of store_code
    name: str
    region_code: str
    tier: int  # 1 = metropolis (largest stores), 3 = smaller city


# Order in which stores are opened: the first 25 cover all 16 voivodeships.
# Cities repeat (Warszawa 2, Kraków 2...) as store_count grows.
CITY_SLOTS: tuple[City, ...] = (
    City("WAW", "Warszawa", "14", 1),
    City("KRK", "Kraków", "12", 1),
    City("WRO", "Wrocław", "02", 1),
    City("POZ", "Poznań", "30", 1),
    City("GDA", "Gdańsk", "22", 1),
    City("LDZ", "Łódź", "10", 1),
    City("KAT", "Katowice", "24", 1),
    City("WAW", "Warszawa", "14", 1),
    City("SZC", "Szczecin", "32", 2),
    City("BYD", "Bydgoszcz", "04", 2),
    City("LUB", "Lublin", "06", 2),
    City("BIA", "Białystok", "20", 2),
    City("KRK", "Kraków", "12", 1),
    City("RZE", "Rzeszów", "18", 2),
    City("OLS", "Olsztyn", "28", 2),
    City("KIE", "Kielce", "26", 2),
    City("OPO", "Opole", "16", 3),
    City("ZGO", "Zielona Góra", "08", 3),
    City("WAW", "Warszawa", "14", 1),
    City("GDY", "Gdynia", "22", 2),
    City("GLI", "Gliwice", "24", 3),
    City("TOR", "Toruń", "04", 3),
    City("WRO", "Wrocław", "02", 1),
    City("RAD", "Radom", "14", 3),
    City("CZE", "Częstochowa", "24", 3),
    City("POZ", "Poznań", "30", 1),
    City("SOS", "Sosnowiec", "24", 3),
    City("BBI", "Bielsko-Biała", "24", 3),
    City("TAR", "Tarnów", "12", 3),
    City("PLO", "Płock", "14", 3),
    City("ELB", "Elbląg", "28", 3),
    City("KOS", "Koszalin", "32", 3),
    City("KAL", "Kalisz", "30", 3),
    City("GOR", "Gorzów Wielkopolski", "08", 3),
    City("LEG", "Legnica", "02", 3),
    City("SLU", "Słupsk", "22", 3),
    City("NSA", "Nowy Sącz", "12", 3),
    City("ZAM", "Zamość", "06", 3),
    City("PRZ", "Przemyśl", "18", 3),
    City("LDZ", "Łódź", "10", 1),
)

# Store floor area range (m2) per city tier.
SIZE_RANGE = {1: (1800, 3200), 2: (1200, 2200), 3: (800, 1500)}


@dataclass(frozen=True)
class Category:
    code: str
    name: str
    margin: float  # target gross margin on list price
    eur_share: float  # share of products bought from foreign suppliers in EUR
    product_share: float  # share of the assortment
    # Monthly demand multipliers (Jan..Dec) on top of the chain-wide seasonality: they shift
    # the product mix, e.g. sport and garden in summer, toys before Christmas.
    season: tuple[float, ...]
    online_affinity: float  # relative popularity in the online store vs stationary stores
    extra_quantity: float  # mean extra units per line (Poisson), e.g. food is bought in multiples
    brands: tuple[str, ...]
    # (base name, min list price, max list price)
    items: tuple[tuple[str, int, int], ...]


CATEGORIES: tuple[Category, ...] = (
    Category(
        "ELEC",
        "Elektronika i AGD",
        0.18,
        0.70,
        0.15,
        (0.9, 0.85, 0.95, 0.95, 0.95, 0.9, 0.85, 0.9, 1.0, 1.05, 1.25, 1.25),
        1.6,
        0.05,
        ("Volt", "Iskra", "Nexa", "Lumio", "Orbit"),
        (
            ("Słuchawki bezprzewodowe", 99, 699),
            ("Głośnik Bluetooth", 79, 899),
            ("Powerbank 20000 mAh", 59, 249),
            ("Smartwatch", 199, 1499),
            ("Ładowarka sieciowa USB-C", 39, 199),
            ("Mysz bezprzewodowa", 39, 299),
            ("Klawiatura mechaniczna", 149, 599),
            ('Monitor 27"', 699, 2499),
            ("Router Wi-Fi 6", 199, 899),
            ("Ekspres do kawy", 499, 3999),
            ("Odkurzacz pionowy", 399, 2499),
            ("Blender kielichowy", 149, 799),
            ("Czajnik elektryczny", 79, 349),
            ("Suszarka do włosów", 89, 499),
            ('Tablet 10"', 599, 2999),
        ),
    ),
    Category(
        "HOME",
        "Dom i ogród",
        0.38,
        0.25,
        0.175,
        (0.8, 0.8, 1.0, 1.25, 1.4, 1.35, 1.2, 1.0, 0.9, 0.85, 0.85, 1.0),
        0.8,
        0.25,
        ("Domek", "Lipa", "Kasztan", "Nordhus", "Zielnik"),
        (
            ("Komplet pościeli 160x200", 99, 399),
            ("Ręcznik kąpielowy", 29, 99),
            ("Patelnia ceramiczna 28 cm", 79, 299),
            ("Zestaw garnków", 199, 899),
            ("Lampa stojąca", 149, 699),
            ("Poduszka dekoracyjna", 29, 119),
            ("Kubek ceramiczny", 19, 59),
            ("Doniczka ceramiczna", 19, 149),
            ("Krzesło ogrodowe", 99, 399),
            ("Grill węglowy", 199, 1299),
            ("Wąż ogrodowy 20 m", 59, 249),
            ("Koc z mikrofibry", 49, 199),
            ("Organizer do szafy", 29, 129),
            ("Świeca zapachowa", 19, 89),
        ),
    ),
    Category(
        "FASH",
        "Moda",
        0.52,
        0.20,
        0.175,
        (1.1, 0.9, 1.0, 1.05, 1.0, 1.0, 1.05, 0.95, 1.05, 1.1, 1.0, 1.0),
        1.2,
        0.2,
        ("Wiślanka", "Urbanica", "Lniany", "Krój", "Polna"),
        (
            ("Koszulka bawełniana", 29, 99),
            ("Bluza z kapturem", 89, 299),
            ("Jeansy", 119, 399),
            ("Kurtka przejściowa", 199, 699),
            ("Sweter wełniany", 149, 449),
            ("Sukienka letnia", 99, 349),
            ("Buty sportowe", 149, 549),
            ("Plecak miejski", 99, 349),
            ("Czapka zimowa", 29, 99),
            ("Szalik", 39, 149),
            ("Pasek skórzany", 59, 199),
            ("Skarpety 3-pak", 19, 49),
        ),
    ),
    Category(
        "SPORT",
        "Sport i turystyka",
        0.34,
        0.35,
        0.11,
        (0.75, 0.75, 0.9, 1.15, 1.3, 1.45, 1.5, 1.35, 1.0, 0.85, 0.75, 0.8),
        1.0,
        0.1,
        ("Tatra", "Beskid", "Rysy", "Orlik", "Szlak"),
        (
            ("Rower trekkingowy", 1499, 3999),
            ("Kask rowerowy", 99, 399),
            ("Mata do jogi", 49, 199),
            ("Hantle 2x5 kg", 79, 249),
            ("Namiot 3-osobowy", 299, 1299),
            ("Śpiwór", 149, 599),
            ("Plecak turystyczny 40 l", 199, 699),
            ("Kijki trekkingowe", 99, 349),
            ("Bidon", 19, 79),
            ("Piłka nożna", 49, 199),
            ("Rolki", 199, 699),
            ("Kurtka softshell", 199, 599),
        ),
    ),
    Category(
        "TOYS",
        "Zabawki",
        0.36,
        0.50,
        0.10,
        (0.7, 0.7, 0.8, 0.85, 1.1, 1.0, 0.8, 0.8, 0.85, 0.95, 1.4, 2.0),
        1.1,
        0.15,
        ("Bajka", "Klocuś", "Zygzak", "Misiek", "Fantazja"),
        (
            ("Klocki konstrukcyjne", 49, 599),
            ("Lalka", 39, 249),
            ("Samochód zdalnie sterowany", 99, 499),
            ("Puzzle 1000 elementów", 39, 99),
            ("Gra planszowa", 59, 249),
            ("Pluszowy miś", 29, 149),
            ("Kolejka drewniana", 99, 399),
            ("Zestaw kreatywny", 29, 149),
            ("Hulajnoga dziecięca", 149, 499),
            ("Klocki magnetyczne", 79, 349),
        ),
    ),
    Category(
        "BEAUTY",
        "Uroda i zdrowie",
        0.46,
        0.20,
        0.125,
        (0.95, 1.0, 1.1, 1.0, 1.0, 1.05, 1.1, 1.05, 0.95, 0.95, 0.95, 1.2),
        1.0,
        0.5,
        ("Lawenda", "Rumianek", "Aloes", "Bursztyn", "Natura"),
        (
            ("Krem nawilżający", 19, 149),
            ("Szampon", 12, 59),
            ("Perfumy 50 ml", 99, 499),
            ("Balsam do ciała", 15, 79),
            ("Serum do twarzy", 39, 199),
            ("Szczoteczka soniczna", 99, 499),
            ("Żel pod prysznic", 9, 39),
            ("Pomadka", 19, 89),
            ("Krem z filtrem SPF 50", 29, 99),
            ("Olejek do brody", 29, 99),
            ("Zestaw do manicure", 39, 149),
        ),
    ),
    Category(
        "FOOD",
        "Delikatesy",
        0.26,
        0.15,
        0.10,
        (0.9, 0.9, 0.95, 1.05, 0.95, 0.9, 0.85, 0.85, 0.95, 1.0, 1.1, 1.5),
        0.6,
        0.7,
        ("Mazurskie Smaki", "Kraina Kawy", "Słodki Kąt", "Złoty Kłos", "Dworek"),
        (
            ("Kawa ziarnista 1 kg", 49, 149),
            ("Herbata liściasta", 15, 69),
            ("Czekolada gorzka", 6, 29),
            ("Miód wielokwiatowy", 29, 79),
            ("Oliwa z oliwek", 29, 89),
            ("Bombonierka", 19, 99),
            ("Makaron włoski", 7, 25),
            ("Konfitura", 12, 35),
            ("Orzechy nerkowca", 19, 49),
            ("Zestaw upominkowy", 79, 299),
        ),
    ),
    Category(
        "BOOKS",
        "Książki i papiernicze",
        0.30,
        0.0,
        0.065,
        (0.9, 0.85, 0.85, 0.85, 0.85, 0.9, 0.95, 1.6, 1.5, 0.9, 1.0, 1.4),
        1.3,
        0.4,
        ("Atrament", "Kartka", "Literka", "Notes", "Papirus"),
        (
            ("Powieść kryminalna", 29, 59),
            ("Poradnik kulinarny", 39, 99),
            ("Książka dla dzieci", 19, 59),
            ("Kalendarz książkowy", 29, 89),
            ("Zeszyt A5", 4, 19),
            ("Długopis żelowy", 5, 29),
            ("Plecak szkolny", 99, 299),
            ("Piórnik", 19, 79),
            ("Kredki 24 kolory", 12, 49),
            ("Album fotograficzny", 39, 129),
        ),
    ),
)

PRODUCT_LINES: tuple[str, ...] = (
    "Basic",
    "Classic",
    "Comfort",
    "Premium",
    "Eco",
    "Max",
    "Mini",
    "Pro",
    "Plus",
    "Lux",
)
