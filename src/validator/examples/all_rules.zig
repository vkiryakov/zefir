//! The examples of the "All rules" index of README.md, compiled: one struct
//! per category, with a field for every rule of the category, declared in
//! `field_rules` exactly as the index shows it. all_rules_test.zig checks
//! that the index and this file agree.

const v = @import("validator");

const Common = struct {
    terms_accepted: bool,
    adjustment: i32,
    currency: []const u8,
    username: []const u8,
    honeypot: []const u8,
    name: []const u8,

    pub const field_rules = .{
        .terms_accepted = v.equals(true),
        .adjustment = v.notEquals(0),
        .currency = v.oneOf(.{ "EUR", "USD" }),
        .username = v.noneOf(.{ "admin", "root" }),
        .honeypot = v.empty,
        .name = v.notEmpty,
    };
};

const Numbers = struct {
    amount_cents: u64,
    discount_percent: u8,
    age: u8,
    quantity: u32,
    balance_cents: i64,
    debit_cents: i64,
    stock_correction: i32,
    duration_minutes: u16,
    weight_kg: f64,

    pub const field_rules = .{
        .amount_cents = v.min(100),
        .discount_percent = v.max(50),
        .age = v.range(18, 120),
        .quantity = v.positive,
        .balance_cents = v.nonNegative,
        .debit_cents = v.negative,
        .stock_correction = v.nonPositive,
        .duration_minutes = v.divisibleBy(15),
        .weight_kg = v.finite,
    };
};

const Role = enum { owner, admin, editor, viewer };

const OrderLine = struct {
    sku: []const u8,
    quantity: u32,
};

const Lists = struct {
    options: []const []const u8,
    attachments: []const []const u8,
    tags: []const []const u8,
    lines: []const OrderLine,
    scopes: []const []const u8,
    roles: []const Role,
    emails: []const []const u8,

    pub const field_rules = .{
        .options = v.minItems(2),
        .attachments = v.maxItems(5),
        .tags = .{ v.maxItems(10), v.uniqueItems },
        .lines = .{ v.maxItems(50), v.uniqueBy(.sku) },
        .scopes = v.containsAll(.{"openid"}),
        .roles = v.containsNone(.{.owner}),
        .emails = v.each(v.email),
    };
};

fn startsWithAt(s: []const u8) bool {
    return s.len > 0 and s[0] == '@';
}

const Custom = struct {
    handle: []const u8,

    pub const field_rules = .{
        .handle = v.custom("profiles.handle_format", "must start with @", startsWithAt),
    };
};

const Strings = struct {
    review: []const u8,
    title: []const u8,
    nickname: []const u8,
    signing_key: []const u8,
    subject: []const u8,
    display_name: []const u8,
    comment: []const u8,
    payment_reference: []const u8,
    api_key: []const u8,
    coupon_code: []const u8,
    country_code: []const u8,
    pin: []const u8,
    slug: []const u8,
    ticker: []const u8,
    native_name: []const u8,
    name_kana: []const u8,
    account_holder_kana: []const u8,
    product_name: []const u8,
    sms_template: []const u8,
    login: []const u8,
    password: []const u8,

    pub const field_rules = .{
        .review = v.minLength(20),
        .title = v.maxLength(120),
        .nickname = v.length(3, 32),
        .signing_key = v.minBytes(32),
        .subject = v.maxBytes(255),
        .display_name = v.utf8,
        .comment = v.notBlank,
        .payment_reference = v.ascii,
        .api_key = v.printableAscii,
        .coupon_code = v.alphanumeric,
        .country_code = v.alpha,
        .pin = .{ v.length(4, 4), v.digits },
        .slug = v.lowercase,
        .ticker = v.uppercase,
        .native_name = v.multibyte,
        .name_kana = v.fullWidth,
        .account_holder_kana = v.halfWidth,
        .product_name = v.variableWidth,
        .sms_template = v.contains("{code}"),
        .login = v.notContains(" "),
        .password = v.strongPassword(.{ .min_length = 12 }),
    };
};

const Formats = struct {
    amount: []const u8,
    price: []const u8,
    newsletter: []const u8,
    nonce: []const u8,
    file_mode: []const u8,
    port: []const u8,
    lat: f64,
    lng: f64,
    location: []const u8,
    email: []const u8,
    website: []const u8,
    domain: []const u8,
    client_ip: []const u8,
    gateway_v4: []const u8,
    gateway_v6: []const u8,
    device_mac: []const u8,

    pub const field_rules = .{
        .amount = v.numberString,
        .price = v.decimal(.{ .max_decimal_digits = 2 }),
        .newsletter = v.booleanString,
        .nonce = v.hexadecimal,
        .file_mode = v.octal,
        .port = v.port,
        .lat = v.latitude,
        .lng = v.longitude,
        .location = v.latLong,
        .email = v.email,
        .website = v.httpUrl,
        .domain = v.fqdn(.{}),
        .client_ip = v.ip,
        .gateway_v4 = v.ipv4,
        .gateway_v6 = v.ipv6,
        .device_mac = v.macAddress(.{}),
    };
};

const Encodings = struct {
    metadata: []const u8,
    id_token: []const u8,
    totp_secret: []const u8,
    public_key: []const u8,
    signature: []const u8,
    code_challenge: []const u8,
    avatar: []const u8,
    magnet_link: []const u8,
    content_type: []const u8,
    language: []const u8,
    version: []const u8,
    brand_color: []const u8,
    background: []const u8,
    accent: []const u8,

    pub const field_rules = .{
        .metadata = v.json,
        .id_token = v.jwt,
        .totp_secret = v.base32,
        .public_key = v.base58,
        .signature = v.base64,
        .code_challenge = v.base64Url,
        .avatar = v.dataUri,
        .magnet_link = v.magnetUri,
        .content_type = v.mimeType,
        .language = v.locale,
        .version = v.semVer,
        .brand_color = v.hexColor,
        .background = v.rgbColor,
        .accent = v.hslColor,
    };
};

const Identifiers = struct {
    request_id: []const u8,
    user_id: []const u8,
    message_id: []const u8,
    digest: []const u8,
    card_number: []const u8,
    isbn: []const u8,
    isbn_10: []const u8,
    isbn_13: []const u8,
    issn: []const u8,
    barcode: []const u8,
    isin: []const u8,
    isrc: []const u8,
    bic: []const u8,
    iban: []const u8,
    wallet: []const u8,
    eth_address: []const u8,

    pub const field_rules = .{
        .request_id = v.uuid,
        .user_id = v.mongoId,
        .message_id = v.firebasePushId,
        .digest = v.hash(.sha256),
        .card_number = v.creditCard,
        .isbn = v.isbn,
        .isbn_10 = v.isbn10,
        .isbn_13 = v.isbn13,
        .issn = v.issn,
        .barcode = v.ean,
        .isin = v.isin,
        .isrc = v.isrc,
        .bic = v.bic,
        .iban = v.iban,
        .wallet = v.btcAddress(.mainnet),
        .eth_address = v.ethereumAddress,
    };
};

const Dates = struct {
    birthday: []const u8,
    created_at: []const u8,
    published_at: []const u8,
    starts: []const u8,
    ends: []const u8,
    opens_at: []const u8,

    pub const field_rules = .{
        .birthday = v.date,
        .created_at = v.rfc3339,
        .published_at = v.iso8601,
        .starts = v.minDate("2020-01-01"),
        .ends = v.maxDate("2030-12-31"),
        .opens_at = v.militaryTime,
    };
};

test "every example of the All rules index fits its field" {
    inline for (.{ Common, Numbers, Lists, Custom, Strings, Formats, Encodings, Identifiers, Dates }) |T| {
        comptime v.assertRules(T);
    }
}
