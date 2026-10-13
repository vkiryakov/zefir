//! The identifier rules through `v.check` and `v.checkAll`: every string
//! type, `?T` and `??T`, the items of `v.each`, codes and messages,
//! `.withMessage` and its placeholders, and the predicates, which give the
//! rules' verdicts and never crash, whatever the input.
const std = @import("std");
const v = @import("validator");
const h = @import("vtest");
const testing = std.testing;

const S = []const u8;

/// One rule in use: a value it passes, a value it fails, and the code and
/// message of the failure.
fn Case(comptime rule: v.Rule, comptime good: S, comptime bad: S, comptime code: S, comptime message: S) type {
    return struct {
        const r = rule;
        const ok = good;
        const no = bad;
        /// The same values as sentinel-terminated strings.
        const ok_z: [:0]const u8 = std.fmt.comptimePrint("{s}", .{good});
        const no_z: [:0]const u8 = std.fmt.comptimePrint("{s}", .{bad});
        const c = code;
        const m = message;
    };
}

const cases = .{
    Case(v.uuid, "f81d4fae-7dec-11d0-a765-00a0c91e6bf6", "f81d4fae-7dec-11d0-a765-00a0c91e6bf", "validation.uuid", "must be a valid UUID"),
    Case(v.mongoId, "507f1f77bcf86cd799439011", "507f1f77bcf86cd79943901", "validation.mongo_id", "must be a valid MongoDB ObjectId"),
    Case(v.firebasePushId, "-JhLeOlGIEjaIOFHR0xd", "-JhLeOlGIEjaIOFHR0x.", "validation.firebase_push_id", "must be a valid Firebase push ID"),
    Case(v.hash(.sha256), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", "d41d8cd98f00b204e9800998ecf8427e", "validation.hash", "must be a valid sha256 hash"),
    Case(v.hash(.md5), "d41d8cd98f00b204e9800998ecf8427e", "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", "validation.hash", "must be a valid md5 hash"),
    Case(v.creditCard, "4111111111111111", "4111111111111112", "validation.credit_card", "must be a valid credit card number"),
    Case(v.isin, "US0378331005", "US0378331006", "validation.isin", "must be a valid ISIN"),
    Case(v.bic, "DEUTDEFF", "deutdeff", "validation.bic", "must be a valid BIC"),
    Case(v.iban, "DE89370400440532013000", "DE89370400440532013001", "validation.iban", "must be a valid IBAN"),
    Case(v.isbn, "9780306406157", "978-0-306-40615-7", "validation.isbn", "must be a valid ISBN"),
    Case(v.isbn10, "0306406152", "9780306406157", "validation.isbn10", "must be a valid ISBN-10"),
    Case(v.isbn13, "9780306406157", "0306406152", "validation.isbn13", "must be a valid ISBN-13"),
    Case(v.issn, "0317-8471", "03178471", "validation.issn", "must be a valid ISSN"),
    Case(v.ean, "4006381333931", "4006381333932", "validation.ean", "must be a valid EAN"),
    Case(v.isrc, "USRC17607839", "US-RC1-76-07839", "validation.isrc", "must be a valid ISRC"),
    Case(v.btcAddress(.mainnet), "bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4", "tb1qw508d6qejxtdg4y5r3zarvary0c5xw7kxpjzsx", "validation.btc_address", "must be a valid Bitcoin address"),
    Case(v.btcAddress(.testnet), "tb1qw508d6qejxtdg4y5r3zarvary0c5xw7kxpjzsx", "bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4", "validation.btc_address", "must be a valid Bitcoin testnet address"),
    Case(v.btcAddress(.any), "1BvBMSEYstWetqTFn5Au4m4GFg7xJaNVN2", "bcrt1qdavt4j2sd7dlhqsavtnfxvzppw6k7qy97tmnu9", "validation.btc_address", "must be a valid Bitcoin address"),
    Case(v.ethereumAddress, "0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed", "0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAeD", "validation.ethereum_address", "must be a valid Ethereum address"),
};

test "every string type: []const u8, []u8, [:0]const u8, [:0]u8" {
    inline for (cases) |c| {
        try h.expectPass(S, c.r, c.ok);
        try h.expectFail(S, c.r, c.no, c.c, c.m);
        var good = c.ok[0..c.ok.len].*;
        var bad = c.no[0..c.no.len].*;
        try h.expectPass([]u8, c.r, &good);
        try h.expectFail([]u8, c.r, &bad, c.c, c.m);
        try h.expectPass([:0]const u8, c.r, c.ok_z);
        try h.expectFail([:0]const u8, c.r, c.no_z, c.c, c.m);
        var good_z = c.ok_z[0..c.ok_z.len :0].*;
        var bad_z = c.no_z[0..c.no_z.len :0].*;
        try h.expectPass([:0]u8, c.r, &good_z);
        try h.expectFail([:0]u8, c.r, &bad_z, c.c, c.m);
    }
}

test "?T and ??T check the string inside; null skips the rule" {
    inline for (cases) |c| {
        try h.expectPass(?S, c.r, null);
        try h.expectPass(?S, c.r, c.ok);
        try h.expectFail(?S, c.r, c.no, c.c, c.m);
        try h.expectPass(??S, c.r, @as(?S, null));
        try h.expectFail(??[:0]const u8, c.r, c.no_z, c.c, c.m);
    }
}

test "inside each: slices and arrays of strings, null items skipped, the item's path" {
    inline for (cases) |c| {
        const List = h.One([]const S, v.each(c.r));
        try h.expectValid(&List{ .x = &.{ c.ok, c.ok } });
        try h.expectAt(&List{ .x = &.{ c.ok, c.no, c.no } }, c.c, c.m, "x[1]");
        try h.expectAll(&List{ .x = &.{ c.no, c.ok, c.no } }, &.{ .{ .code = c.c, .field = "x[0]" }, .{ .code = c.c, .field = "x[2]" } });
        const Optional = h.One([]const ?S, v.each(c.r));
        try h.expectAt(&Optional{ .x = &.{ null, c.ok, c.no } }, c.c, c.m, "x[2]");
        const Array = h.One([2][:0]const u8, v.each(c.r));
        try h.expectAt(&Array{ .x = .{ c.ok_z, c.no_z } }, c.c, c.m, "x[1]");
    }
}

test "the empty string and invalid UTF-8 fail under the rule's own code: there is no precondition" {
    inline for (cases) |c| {
        try testing.expectEqual(null, c.r.precondition);
        try h.expectFail(S, c.r, "", c.c, c.m);
        try h.expectFail(S, c.r, "\xff", c.c, c.m);
        try h.expectFail(S, c.r, c.ok[0 .. c.ok.len - 1] ++ "\xc3", c.c, c.m);
        try h.expectFail(S, c.r.withMessage("bad bytes"), "\xff\xfe", c.c, "bad bytes");
    }
}

test "withMessage keeps the code and replaces the message, in any language" {
    inline for (cases) |c| {
        const custom = comptime c.r.withMessage("неверное значение");
        try h.expectRule(custom, c.c, "неверное значение");
        try h.expectFail(S, custom, c.no, c.c, "неверное значение");
        try h.expectPass(S, custom, c.ok);
    }
}

test "hash shows its algorithm through {algorithm}" {
    inline for (comptime std.enums.values(v.HashAlgorithm)) |algorithm| {
        const rule = comptime v.hash(algorithm).withMessage("expected a {algorithm} digest ({{algorithm}})");
        try h.expectRule(rule, "validation.hash", "expected a " ++ @tagName(algorithm) ++ " digest ({algorithm})");
        try h.expectFail(S, rule, "xyz", "validation.hash", "expected a " ++ @tagName(algorithm) ++ " digest ({algorithm})");
    }
}

test "btcAddress shows its network through {network}" {
    inline for (comptime std.enums.values(v.BtcNetwork)) |network| {
        const rule = comptime v.btcAddress(network).withMessage("must be a {network} Bitcoin address");
        try h.expectRule(rule, "validation.btc_address", "must be a " ++ @tagName(network) ++ " Bitcoin address");
        try h.expectFail(S, rule, "", "validation.btc_address", "must be a " ++ @tagName(network) ++ " Bitcoin address");
    }
}

test "the selectors of isHash and isBtcAddress may be known at run time only" {
    var algorithm: v.HashAlgorithm = .md5;
    _ = &algorithm;
    try testing.expect(v.isHash("d41d8cd98f00b204e9800998ecf8427e", algorithm));
    algorithm = .sha1;
    try testing.expect(!v.isHash("d41d8cd98f00b204e9800998ecf8427e", algorithm));
    var network: v.BtcNetwork = .testnet;
    _ = &network;
    try testing.expect(v.isBtcAddress("tb1qw508d6qejxtdg4y5r3zarvary0c5xw7kxpjzsx", network));
    network = .mainnet;
    try testing.expect(!v.isBtcAddress("tb1qw508d6qejxtdg4y5r3zarvary0c5xw7kxpjzsx", network));
}

test "btcAddress: the network selects the addresses; .any takes both" {
    inline for (.{ "bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4", "3J98t1WpEZ73CNmQviecrnyiWrnqRhWNLy" }) |main| {
        try h.expectPass(S, v.btcAddress(.mainnet), main);
        try h.expectPass(S, v.btcAddress(.any), main);
        try h.expectFail(S, v.btcAddress(.testnet), main, "validation.btc_address", "must be a valid Bitcoin testnet address");
    }
    inline for (.{ "tb1qw508d6qejxtdg4y5r3zarvary0c5xw7kxpjzsx", "2NC2hEhe28ULKAJkW5MjZ3jtTMJdvXmByvK" }) |testnet| {
        try h.expectPass(S, v.btcAddress(.testnet), testnet);
        try h.expectPass(S, v.btcAddress(.any), testnet);
        try h.expectFail(S, v.btcAddress(.mainnet), testnet, "validation.btc_address", "must be a valid Bitcoin address");
    }
}

/// Mainnet addresses of the Bitcoin Core test list.
const core_mainnet = [_]S{
    "1FsSia9rv4NeEwvJ2GvXrX7LyxYspbN2mo",
    "36j4NfKv6Akva9amjWrLG6MuSQym1GuEmm",
    "bc1qvyq0cc6rahyvsazfdje0twl7ez82ndmuac2lhv",
    "bc1qyucykdlhp62tezs0hagqury402qwhk589q80tqs5myh3rxq34nwqhkdhv7",
    "bc1p83n3au0rjylefxq2nc2xh2y4jzz4pm6zxj4mw5pagdjjr2a9f36s6jjnnu",
    "bc1z2rksukkjr8",
    "1FjL87pn8ky6Vbavd1ZHeChRXtoxwRGCRd",
    "3BZECeAH8gSKkjrTx8PwMrNQBLG18yHpvf",
    "bc1qhxt04s5xnpy0kxw4x99n5hpdf5pmtzpqs52es2",
    "bc1qgc9ljrvdf2e0zg9rmmq86xklqwfys7r6wptjlacdgrcdc7sa6ggqu4rrxf",
    "bc1pve739yap4uxjvfk0jrey69078u0gasm2nwvv483ec6zkzulgw9xqu4w9fd",
    "bc1zmjtqxkzs89",
    "1G9A9j6W8TLuh6dEeVwWeyibK1Uc5MfVFV",
    "33GA3ZXbw5o5HeUrBEaqkWXFYYZmdxGRRP",
};

/// Testnet, signet and regtest addresses of the Bitcoin Core test list that
/// `.testnet` takes: regtest and signet share the testnet version bytes, and
/// signet the `tb1` prefix.
const core_testnet = [_]S{
    "mzK2FFDEhxqHcmrJw1ysqFkVyhUULo45hZ",
    "2NC2hEhe28ULKAJkW5MjZ3jtTMJdvXmByvK",
    "mww4LvqtTMKvmeQvizPz2EQv26xTneWrbg",
    "2N1r7aC69VHeE7yQJPDLi9T1PYq4wnwvjuT",
    "n4fajahJrAuKbN7uNsKjLjQkz9Qn5ewJXQ",
    "2MxFajLApXpYk4VodBSZSt7rw8y4ryABkfA",
    "tb1qcrh3yqn4nlleplcez2yndq2ry8h9ncg3qh7n54",
    "tb1quyl9ujpgwr2chdzdnnalen48sup245vdfnh2jxhsuq3yx80rrwlq5hqfe4",
    "tb1p35n52jy6xkm4wd905tdy8qtagrn73kqdz73xe4zxpvq9t3fp50aqk3s6gz",
    "tb1rgv5m6uvdk3kc7qsuz0c79v88ycr5w4wa",
    "tb1q3vya2h5435jkugq2few7dmktlrwq4ejmfaw7kr",
    "tb1qxkhrl2s6ttrclckldruea0e8anhrehffl8xv7t0pdyrzm08v2hyqy408nf",
    "tb1pae5um27ahn8n73pgexe3kcwlp8dhswpn684h2k2w6t9a7w3eq65qephd5y",
    "tb1rx9n9g37az8mu236e5jpxdt0m67y4fuq8rhs0ss3djnm0kscfrwvq0ntlyg",
    "n4YNbYuFdPwFrxSP8sjHFbAhUbLMUiY9jE",
    "2NAeQVZayzVFAtgeC3iYJsjpjWDmsDph71A",
    "mnCBpkNMJEJLehgdEkzSo2eioniyJMxLpZ",
    "2N5sNHomeNJDZv67AcFx9ES7FBZY4jx9KDA",
    "mfhE6jAUwjUDNZhaX1PAsDTKfneQF2Nshc",
    "2MxNm1VHyVU4RuP3u1c1v5aQLk2dQjwy1Qk",
    "tb1ql4k5ayv7p7w0t0ge7tpntgpkgw53g2payxkszr",
    "tb1q9jx3x2qqdpempxrcfgyrkjd5fzeacaqj4ua7cs7fe2sfd2wdaueq5wn26y",
    "tb1pdswckwd9ym5yf5eyzg8j4jjwnzla8y0tf9cp7aasfkek0u29sz9qfr00yf",
    "tb1r0ecpfxg2udhtc556gqrpwwhk4sw3f0kc",
    "tb1q6mwf89hnqhlu8txjgjfs4s7p93ugffn3k062ll",
    "tb1qafrjalu4d73dql0czau9j6z422434kef235mzljf48ckd5xz3sys09jm97",
    "tb1pwst9qszjrhuv2e7as0flcq9gm698v6gdxzz9e87p07s8rssdx3zqklm3vf",
    "tb1r3ss76jtsuxe8c8c8lxsehnpak55ylrgr345pww076l536ahjr6jsydamx3",
    "mwgS2HRbjyfYxFnR1nF9VKLvmdgMfFBmGq",
    "2MwBVrJQ76BdaGD76CTmou8cZzQYLpe4NqU",
    "mfnJ8tEkqKNFE5YaHTXFxyHk2mnDK2fvDh",
    "2My83D67ir7K8PPzeT6mE2oth3ZwNTVRS9F",
};

/// Regtest segwit addresses of the Bitcoin Core test list: `bcrt1` passes no
/// network.
const core_regtest = [_]S{
    "bcrt1qdavt4j2sd7dlhqsavtnfxvzppw6k7qy97tmnu9",
    "bcrt1qan8gntac7z7me2ejt4hpru42ad2f759fmy0m3ejvs98656znv7eqga4uhv",
    "bcrt1pfwxjqvtt4tcxrtdluukfmy2dv7xd2qzdfy6kajv5nwn4yam3wxkq3553uh",
    "bcrt1sx6p8njlx7h9mc2agz4yg82dzne23050ncq72cneeecez2pst8mahn8xecsf8g6hzx94420",
    "bcrt1q65nhlm4hf2ptg3t264al57p7wjxj2c3s6kyt83",
    "bcrt1qawvc90lpytw3z3k9etdx54l0exq5f5sqfzu5e45kjnl6slwayeeqx2dyac",
    "bcrt1p39a4s4vdcw9kqa8w2t0rp7aj8kfxyw7mce5sk5d70x6wnnmpvt7skf2kxy",
    "bcrt1s489d9fhmyel0vzfqsrmew4x7r80asuqesm5hgqacy35daflcyufh3j8cgdtflvt99ph05m",
};

/// Invalid addresses of the Bitcoin Core test list.
const core_invalid = [_]S{
    "",
    "x",
    "1GAdfviErV2Ew95FPtZyikz2qGP3gyCB6Hyu94sedAkPpA523m3fQwps9YKUZkKgQckGPKhRsFR",
    "37G2kMDLpmWVhimxRdzwNfE8JFvWXnJYnVcXeeGrek2qumdJuK7XArcVVpRtLLjRra3t64BEPF2",
    "giymtio7u7oqWtmC9YnvAEKkLF3JQpAdkEFkVJKYrVDfaLbhaDpX1ihfF2vZmya1i61fwLPC3YQ",
    "8iVk9nLM3nYwRuwypjy9NK5rsuZH7BbrQRZ1pgcQmvMnjAgRXD",
    "cPTVQ1hbo4qdoysf6Jx5GthqucNmdfqt6J2pZRFeXv8Ep7Kmjqud",
    "cQbR2Ny85XFBzUMx3Ed6HsTLw2pVruSgPvt5AofnBUnhiv86gYeW",
    "2UB3iG3VJbX2TRrMwm6ssWskgvU9VjFBYSqCzwqkrihCwo7mg4mtS4WuGZgxTKuxf5A3EcotYEymz",
    "cQe12pqwPR6ExtZKfrKf1q4b3CTh1Qi7MwuvMvzs79nWXDvESfBJ",
    "tc1qeul5g2xfkvdkrhcfmdursv73ad64jnkjl9c40f",
    "bt1pq65rzej5glw3ra79gav6fqnx4haa0z257qr3mc8cggkefahmgvyseufhc0",
    "tb13hty4qmumlwpp6chxjvcyzza4duqgtmxw3xhm3u9ahj4nyhtwz8eq7ynrj4",
    "bcrt1r2qxpwuge",
    "bc10uexgzna2dpfk0vjt35srz6a27ps6m0l89jweznt83n2sqn2fx4hvn9ym5af8wut34sfrqhk3",
    "tb1qum6uh0pt4q253qaf520929737v63w5gf",
    "bcrt1q888ryfgxpvl0k7vum8zpyar2u2sexvdhkf38ue37yknmqq0ycrwpl3w48y",
    "bc1qdsuzmn04k2z8vryw8l4dj8m5ygqgnne5n",
    "tb1qlj8es50nc8j8r8xshrjgzmw5azx89efghmw8ju6zcqla0g6xcnrstsjz7k",
    "bcrt1qzwmyj0z924g7fzs5yvnrkc43y76RVyr2lh5t4r",
    "bc1qpu6d26mrulzetu4jqhd7rsunv9aqru26f5c4j8",
    "tb1qun6d26ufh77ghny6u5u8cwz9da7qwc6k4wkuceae9tth06eqlw0syupl4w",
    "bcrt1qj7g2jps453kj9htk9cxyyc2nxe69x4kzzmth7v",
    "bc1p702xksx4z3uqf0u2phllxkfe5cgu0adxptqs0uelx0tqt8e885sqryes2l",
    "tb1z7gmh0v6pc30z4xum76lmw8w86yswrlmw",
    "bcrt1sjsrw6nun4h502cr97xmnyyuhkr22q0s6efrgtu",
    "2UVPFpGYnLHJezFzjUo42our6PMEoozzRdM",
    "2MygHQjE1U33q3LSC53p69YqFjP8PihumJAF",
    "KzNbAQ4mexfAxa6RKBzHQqfoTycaeWpv2p",
    "2jDPrDfAKihCGPbPD9ztY8TswAia4V8Bc6vx",
    "4VQUNG1hG64QFtaNyQZQWDdwpxB275Pwb3tvyPt2HDxB8Mi2MgH8Tz3AC83YYiz9LydsLNXEZJLHY",
    "39TKsUQ5QpEL1wowc6GMUqak94ijirPuP69ooV3xsFmiKQX2dau",
    "2UEJjT3dSdwc8dAo7oedPzznXceXCEsBbDfAvSymqpqDrkZMv7JBEUpLyhkghioYAWC9W4sKysry",
    "7VmMEkphxCFSV1y659Th4dkk6x6bJS5eQvbt8rzUYKQyd6ACgwQ4vXHtXKFUwP2kW3XULipnHJdZ7",
    "tc1qdlapns4zkn03juf2k9xwwpct209suj6mgcd9gh",
    "bt1psa5eptk29c4jc9yumeseat3a0l5e2fpmw635za2p4gpwdnthueysxga9je",
    "tb13w8c43lykfj3lvm9sgp6dsnfjla3d57cm83seykunf0ltxjc9lt2q4efm4d",
    "bcrt1rjqr2tdkm",
    "bc10lyxwnxa70l270e6fcmxr4x7dtgu2yvy7gzkurwxy4zhdvgaqrrn6pfg2flyhqzy5t5se8yu3",
    "TB1QFDFM763VXVSUNZHQLPWC0Q8FG5LJX6ZN",
    "bcrt1q60chha7wfwlau4kdr4mlvyeyc8mnnh9dhxk05e0hmrxcuhghefj36uwyha",
    "bc1gmk9yu",
    "tb1ly0q7p",
    "bcrt1qdwttaw38uf42wxw40kwk3u8nguyTQH3hx6jmqp",
    "bc1qtsvlht6730n04f2mpaj5vv8hrledn5n5ug8c79",
    "tb1dclvmr",
    "bcrt1q3fqvctqu48wsvggrt09vj0yk2gzzcscdp4h98u",
    "bc1prklpq7tjcawg89cmwwqr3u5apwav36xa4zz56ady7crsllm6mpnqts7p86",
    "tb1zkm58zyhxz3ffkfgsyprflg543slsl4c4",
    "bcrt1snzr5kaypnfhpnjanrhd20fhqcjxm3hfh7dw9fu",
    "2GgnYKqBGuA2Mm5GnrPsMTZR81xPhNtgMYoFUZngZGiobhCuUpCaTriUHRcgFreEekNdPAR17q8d",
    "AZEah8d1EK362okRBS66e8SvdtYkrE8tsX",
    "gep8xr77FyPW6zYP15RiV9W8nL6w2HyHB16cUDakfyDceMA6ZzUdhJjk2LPuLYHnLkBqkRTTi6z",
    "2NDNP7GY59tTJPZTpbkprhM9SR99Nn5rUs7",
    "2Csgzy2T287YAjeU5tFtt1nPshBZAUFQi4WtgaWyZGKSBNnKXHy2Tmxo8QK4Mfdds977ShcDWC5o",
    "Kwjk3Vy6sdXMQDGWJzaWmqFxUNtWZCX1q4F4Kpt8jNNUoWJUUaTY",
    "Svj8kk98bAS9V4L2crmxakbhmnPm3cJ1tJ4Je4yVzDreU8eSTFURS1SPYv5oWEQD8Q9VBDvx5uF",
    "KNYsv6v9GtkGeD4WdQnBEJCrPKQm91PTxAbCfXr66LEd4JDmhPWC",
    "2UJ2H2xvAeXmFKfQwMyDoSdQTTPFMNCT3SsoUafBWKzoGP3NsUK1buEgQZG38viyD53jgMdpqfT7",
    "6aLMfayKF4TW4ecn5SEc8FExpyJA2peKxYRGZhes6tQ4NTTzuGy",
    "7VP4FmcebU2thJns9MnXde7LWfuqR5vMizrAuUoq2GcJjzTyA4RHFcPVdZL8PLg1SbpSFdJrvLXoY5",
    "tc1q5qdvt99uc92jyz663dtdpfpv6nr67ahmgwcpq2",
    "bt1peu3ppd7x796sjjenp09r8cs22rhylqm9lhggk72qp8q22vzft0wq2a0x6j",
    "tb1323z3lnz7dl3kd0nsuh6xy4he9almzl67anxgg3xdzkaxc9rwntlqdhdzd7",
    "bcrt1r2gc42sky",
    "bc10fd889x4hd54tqu2ewg9t4hhft2wl7m6x50av4uswzw46xe6as0xmltfg7vrjfkvm459vld7w",
    "TB1QZY7V0F2AT3308YGGNGN66ULJTCN3RY6F",
    "bcrt1qjg3cwht92znyw0l4r5rtctmls337nrc7g0ry9drjxmlecjd3atl3fake7c",
    "bc1qmgf8xt8xkecl79k04mma3lz34gqep7hg4",
    "TB1Q3F9WGNXE9ZMTTMDN5VKVKHYZ8Y0LCV72YV7V5LSXTJXEYHNHEHASLYL0TZ",
};

/// `v.isBtcAddress` gives `s` these verdicts on mainnet and on testnet, and
/// their `or` on `.any`.
fn expectBtc(s: S, mainnet: bool, testnet: bool) !void {
    const got = [3]bool{ v.isBtcAddress(s, .mainnet), v.isBtcAddress(s, .testnet), v.isBtcAddress(s, .any) };
    const want = [3]bool{ mainnet, testnet, mainnet or testnet };
    if (!std.mem.eql(bool, &got, &want)) {
        std.debug.print("\"{f}\": mainnet, testnet, any expected {any}, got {any}\n", .{ std.zig.fmtString(s), want, got });
        return error.TestUnexpectedResult;
    }
}

test "btcAddress follows the Bitcoin Core test list; segwit addresses pass in lower case only" {
    var buf: [90]u8 = undefined;
    for (core_mainnet) |s| try expectBtc(s, true, false);
    for (core_testnet) |s| try expectBtc(s, false, true);
    for (core_regtest) |s| try expectBtc(s, false, false);
    for (core_invalid) |s| try expectBtc(s, false, false);
    var flips: usize = 0;
    for (core_mainnet ++ core_testnet ++ core_regtest) |s| {
        if (!std.mem.startsWith(u8, s, "bc1") and !std.mem.startsWith(u8, s, "tb1") and !std.mem.startsWith(u8, s, "bcrt1")) continue;
        try expectBtc(std.ascii.upperString(buf[0..s.len], s), false, false);
        flips += 1;
    }
    try testing.expectEqual(32, flips);
}

/// The examples of the SWIFT IBAN registry: 97 official ones and 24 of
/// countries outside it.
const registry_ibans = [_]S{
    "AL47212110090000000235698741",   "AD1200012030200359100100",          "AT611904300234573201",             "AZ21NABZ00000000137010001944",
    "BH67BMAG00001299123456",         "BE68539007547034",                  "BA391290079401028494",             "BR9700360305000010009795493P1",
    "VG96VPVG0000012345678901",       "BG80BNBG96611020345678",            "BI4210000100010000332045181",      "BY13NBRB3600900000002Z00AB00",
    "CG3930013020003710721836132",    "CR05015202001026284066",            "HR1210010051863000160",            "CY17002001280000001200527600",
    "CZ6508000000192000145399",       "DK5000400440116243",                "FO2000400440116243",               "GL2000400440116243",
    "DJ2100010000000154000100186",    "DO28BAGR00000001212453611324",      "SV62CENR00000000000000700025",     "EE382200221020145685",
    "FI2112345600000785",             "AX2112345600000785",                "FR1420041010050500013M02606",      "GF4120041010050500013M02606",
    "PF5720041010050500013M02606",    "TF2120041010050500013M02606",       "GP1120041010050500013M02606",      "MQ5120041010050500013M02606",
    "YT3120041010050500013M02606",    "NC8420041010050500013M02606",       "RE4220041010050500013M02606",      "BL6820041010050500013M02606",
    "MF8420041010050500013M02606",    "PM3620041010050500013M02606",       "WF9120041010050500013M02606",      "GE29NB0000000101904917",
    "DE89370400440532013000",         "GI75NWBK000000007099453",           "GR1601101250000000012300695",      "GT82TRAJ01020000001210029690",
    "HN88CABF00000000000250005469",   "HU42117730161111101800000000",      "IS140159260076545510730339",       "IQ98NBIQ850123456789012",
    "IE29AIBK93115212345678",         "IL620108000000099999999",           "IT60X0542811101000000123456",      "JO94CBJO0010000000000131000302",
    "KZ86125KZT5004100100",           "XK051212012345678906",              "KW81CBKU0000000000001234560101",   "LV80BANK0000435195001",
    "LB62099900000001001901229114",   "LI21088100002324013AA",             "LT121000011101001000",             "LU280019400644750000",
    "MK07250120000058984",            "MT84MALT011000012345MTLCAST001S",   "MR1300020001010000123456753",      "MU17BOMM0101101030300200000MUR",
    "MD24AG000225100013104168",       "MC5811222000010123456789030",       "ME25505000012345678951",           "NL91ABNA0417164300",
    "NI45BAPR00000013000003558124",   "NO9386011117947",                   "OM810180000001299123456",          "PK36SCBL0000001123456702",
    "PS92PALS000000000400123456702",  "PL61109010140000071219812874",      "PT50000201231234567890154",        "QA58DOHB00001234567890ABCDEFG",
    "RO49AAAA1B31007593840000",       "RU0304452522540817810538091310419", "LC55HEMM000100010012001200023015", "SM86U0322509800000000270100",
    "ST68000100010051845310112",      "SA0380000000608010167519",          "RS35260005601001611379",           "SC18SSCB11010000000000001497USD",
    "SK3112000000198742637541",       "SI56191000000123438",               "ES9121000418450200051332",         "SD2129010501234001",
    "SE4550000000058398257466",       "CH9300762011623852957",             "TL380080012345678910157",          "TN5910006035183598478831",
    "TR330006100519786457841326",     "AE070331234567890123456",           "GB29NWBK60161331926819",           "VA59001123000012345678",
    "YE15CBYE0001018861234567891234", "DZ3512341234123412341234",          "AO44123412341234123412341",        "BJ83A12312341234123412341234",
    "BF4512341234123412341234123",    "CM1512341234123412341234123",       "CV05123412341234123412341",        "CF4220001000010120069700160",
    "TD8960003000203710253860174",    "KM4600005000010010904400137",       "CI77A12312341234123412341234",     "EG380019000500000000263180002",
    "GQ7050002001003715228190196",    "GA2142001007341520000106963",       "GW04GW1430010181800637601",        "AA110011123Z5678",
    "IR081234123412341234123412",     "MG4012341234123412341234123",       "ML75A12312341234123412341234",     "MA64011519000001205000534921",
    "MZ97123412341234123412341",      "NE58NE0380100100130305000268",      "SN15A12312341234123412341234",     "TG53TG0090604310346500400070",
    "UA213996220000026007233566001",
};

test "iban passes every example of the IBAN registry, and no single wrong digit in them" {
    try testing.expectEqual(121, registry_ibans.len);
    var buf: [34]u8 = undefined;
    for (registry_ibans) |example| {
        try h.expectPass(S, v.iban, example);
        const s = buf[0..example.len];
        for (example, 0..) |c, i| {
            if (!std.ascii.isDigit(c)) continue;
            for ("0123456789") |d| {
                if (d == c) continue;
                @memcpy(s, example);
                s[i] = d;
                try testing.expect(!v.isIban(s));
            }
        }
    }
}

test "the Luhn check of creditCard and isin catches every single wrong digit" {
    var buf: [19]u8 = undefined;
    for ([_]S{ "4111111111111111", "378282246310005", "2200700000000009", "0000000000000", "4000000000000000006" }) |number| {
        try testing.expect(v.isCreditCard(number));
        const s = buf[0..number.len];
        for (0..number.len) |i| {
            for ("0123456789") |d| {
                if (d == number[i]) continue;
                @memcpy(s, number);
                s[i] = d;
                try testing.expect(!v.isCreditCard(s));
            }
        }
    }
    for ([_]S{ "US0378331005", "AU0000XVGZA3", "DE000BAY0017" }) |code| {
        try testing.expect(v.isIsin(code));
        const s = buf[0..code.len];
        for (code, 0..) |c, i| {
            if (!std.ascii.isDigit(c)) continue;
            for ("0123456789") |d| {
                if (d == c) continue;
                @memcpy(s, code);
                s[i] = d;
                try testing.expect(!v.isIsin(s));
            }
        }
    }
}

test "the check digits of isbn10, isbn13, issn and ean catch every single wrong digit" {
    const numbers = .{
        .{ v.isIsbn10, [_]S{ "0306406152", "080442957X", "0000000000" } },
        .{ v.isIsbn13, [_]S{ "9780306406157", "9791090636071", "9780000000002" } },
        .{ v.isIssn, [_]S{ "0317-8471", "2434-561X", "1050-124X" } },
        .{ v.isEan, [_]S{ "4006381333931", "73513537", "12345678901231" } },
    };
    var buf: [14]u8 = undefined;
    inline for (numbers) |row| {
        for (row[1]) |number| {
            try testing.expect(row[0](number));
            const s = buf[0..number.len];
            for (number, 0..) |c, i| {
                if (!std.ascii.isDigit(c)) continue;
                for ("0123456789") |d| {
                    if (d == c) continue;
                    @memcpy(s, number);
                    s[i] = d;
                    try testing.expect(!row[0](s));
                }
            }
        }
    }
}

test "the first failing rule is the value's only violation" {
    try h.expectFail(S, .{ v.notEmpty, v.uuid }, "", "validation.not_empty", "must not be empty");
    try h.expectFail(S, .{ v.uuid, v.notEmpty }, "", "validation.uuid", "must be a valid UUID");
    try h.expectFail(S, .{ v.mongoId, v.noneOf(.{"000000000000000000000000"}) }, "000000000000000000000000", "validation.none_of", "must not be 000000000000000000000000");
    try h.expectFail(S, .{ v.hash(.md5), v.hash(.sha1) }, "d41d8cd98f00b204e9800998ecf8427e", "validation.hash", "must be a valid sha1 hash");
    try h.expectFail(S, .{ v.isbn10, v.isbn13 }, "9780306406157", "validation.isbn10", "must be a valid ISBN-10");
    try h.expectFail(S, .{ v.isbn10, v.isbn13 }, "0306406152", "validation.isbn13", "must be a valid ISBN-13");
    try h.expectPass(S, .{ v.isbn, v.isbn13 }, "9780306406157");
    const Books = h.One([]const S, .{ v.maxItems(3), v.each(.{ v.notEmpty, v.isbn.withMessage("bad ISBN") }) });
    try h.expectAt(&Books{ .x = &.{ "9780306406157", "" } }, "validation.not_empty", "must not be empty", "x[1]");
    try h.expectAt(&Books{ .x = &.{ "9780306406157", "0306406153" } }, "validation.isbn", "bad ISBN", "x[1]");
}

// ------------------------------------------------------------------ random input

/// Random input per run of the test below, from each of its three sources.
const iterations = 20_000;

/// The bytes that the grammars of the rules care about, and some they reject.
const alphabet = "0123456789abcdefABCDEF" ++ "0123456789" ++ "GHKLMNPQRSTUVWXYZ" ++ "qpzry9x8gf2tvdw0s3jn54khce6mua7l" ++ "ijkmno" ++ "-_" ++ "X-" ++ " \x00\x7f\x80\xff";

/// The lengths the rules check for, give or take one byte.
const lengths = [_]usize{ 8, 9, 10, 11, 12, 13, 14, 15, 16, 19, 20, 22, 24, 26, 32, 34, 35, 36, 40, 42, 48, 62, 64, 74, 90, 96, 128 };

/// Valid identifiers: edits of them reach checks that random bytes rarely
/// reach.
const seeds = [_]S{
    "f81d4fae-7dec-11d0-a765-00a0c91e6bf6",
    "507f1f77bcf86cd799439011",
    "-JhLeOlGIEjaIOFHR0xd",
    "cbf43926",
    "d41d8cd98f00b204e9800998ecf8427e",
    "da39a3ee5e6b4b0d3255bfef95601890afd80709",
    "3293ac630c13f0245f92bbb1766e16167a4e58492dde73f3",
    "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
    "38b060a751ac96384cd9327eb1b1e36a21fdb71114be07434c0cc7bf63f6e1da274edebfe76f65fbd51ad2f14898b95b",
    "cf83e1357eefb8bdf1542850d66d8007d620e4050b5715dc83f4a921d36ce9ce47d0d13c5d85f2b0ff8318d2877eec2f63b931bd47417a81a538327af927da3e",
    "4111111111111111",
    "675900000000",
    "4000000000000000006",
    "US0378331005",
    "AU0000XVGZA3",
    "DEUTDEFF",
    "DEUTDEFF500",
    "DE89370400440532013000",
    "NO9386011117947",
    "XX621234567890ABCDEFGHIJ1234567890",
    "9780306406157",
    "080442957X",
    "2434-561X",
    "73513537",
    "12345678901231",
    "USRC17607839",
    "1BvBMSEYstWetqTFn5Au4m4GFg7xJaNVN2",
    "3J98t1WpEZ73CNmQviecrnyiWrnqRhWNLy",
    "2NC2hEhe28ULKAJkW5MjZ3jtTMJdvXmByvK",
    "1111111111111111111114oLvT2",
    "bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4",
    "tb1qrp33g0q5c5txsp9arysrx4k6zdkfs4nce4xj0gdcccefvpysxf3q0sl5k7",
    "bc1pw508d6qejxtdg4y5r3zarvary0c5xw7kw508d6qejxtdg4y5r3zarvary0c5xw7kt5nd6y",
    "bc1z2rksukkjr8",
    "0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed",
    "0x5aaeb6053f3e94c9b9a09f33669435e7ef1beaed",
};

/// `rule` passes `s` exactly when `predicate` accepts it.
fn agree(comptime rule: v.Rule, comptime predicate: fn (S) bool, s: S) !void {
    const dto: h.One(S, rule) = .{ .x = s };
    var path_buf: [8]u8 = undefined;
    const passed = v.check(&dto, &path_buf) == null;
    if (passed != predicate(s)) {
        std.debug.print("{s} passes \"{f}\": {}, its predicate says {}\n", .{ comptime rule.call(), std.zig.fmtString(s), passed, !passed });
        return error.TestRuleDisagreesWithPredicate;
    }
}

/// `v.isHash(s, algorithm)` as a predicate of one argument.
fn isHashOf(comptime algorithm: v.HashAlgorithm) fn (S) bool {
    return struct {
        fn f(s: S) bool {
            return v.isHash(s, algorithm);
        }
    }.f;
}

/// `v.isBtcAddress(s, network)` as a predicate of one argument.
fn isBtcAddressOn(comptime network: v.BtcNetwork) fn (S) bool {
    return struct {
        fn f(s: S) bool {
            return v.isBtcAddress(s, network);
        }
    }.f;
}

/// Every predicate on `s`, each against its rule.
fn agreeAll(s: S) !void {
    try agree(v.uuid, v.isUuid, s);
    try agree(v.mongoId, v.isMongoId, s);
    try agree(v.firebasePushId, v.isFirebasePushId, s);
    try agree(v.creditCard, v.isCreditCard, s);
    try agree(v.isin, v.isIsin, s);
    try agree(v.bic, v.isBic, s);
    try agree(v.iban, v.isIban, s);
    try agree(v.isbn, v.isIsbn, s);
    try agree(v.isbn10, v.isIsbn10, s);
    try agree(v.isbn13, v.isIsbn13, s);
    try agree(v.issn, v.isIssn, s);
    try agree(v.ean, v.isEan, s);
    try agree(v.isrc, v.isIsrc, s);
    inline for (comptime std.enums.values(v.BtcNetwork)) |network| try agree(v.btcAddress(network), isBtcAddressOn(network), s);
    try agree(v.ethereumAddress, v.isEthereumAddress, s);
    inline for (comptime std.enums.values(v.HashAlgorithm)) |algorithm| try agree(v.hash(algorithm), isHashOf(algorithm), s);
}

/// Random bytes; or bytes of `alphabet` at one of `lengths`, sometimes one
/// byte off; or a seed with 1 to 3 random edits.
fn randomInput(random: std.Random, buf: []u8) S {
    switch (random.uintLessThan(u8, 3)) {
        0 => {
            const len = random.uintAtMost(usize, buf.len);
            random.bytes(buf[0..len]);
            return buf[0..len];
        },
        1 => {
            var len = lengths[random.uintLessThan(usize, lengths.len)];
            switch (random.uintLessThan(u8, 4)) {
                0 => len -= 1,
                1 => len += 1,
                else => {},
            }
            for (buf[0..len]) |*c| c.* = alphabet[random.uintLessThan(usize, alphabet.len)];
            return buf[0..len];
        },
        else => {
            const seed = seeds[random.uintLessThan(usize, seeds.len)];
            var len = seed.len;
            @memcpy(buf[0..len], seed);
            for (0..1 + random.uintLessThan(u8, 3)) |_| {
                switch (random.uintLessThan(u8, 4)) {
                    0 => buf[random.uintLessThan(usize, len)] = alphabet[random.uintLessThan(usize, alphabet.len)],
                    1 => buf[random.uintLessThan(usize, len)] = random.int(u8),
                    2 => if (len < buf.len) {
                        const at = random.uintAtMost(usize, len);
                        std.mem.copyBackwards(u8, buf[at + 1 .. len + 1], buf[at..len]);
                        buf[at] = alphabet[random.uintLessThan(usize, alphabet.len)];
                        len += 1;
                    },
                    else => if (len > 1) {
                        const at = random.uintLessThan(usize, len);
                        std.mem.copyForwards(u8, buf[at .. len - 1], buf[at + 1 .. len]);
                        len -= 1;
                    },
                }
            }
            return buf[0..len];
        },
    }
}

test "random input never crashes a predicate, and each rule agrees with its predicate" {
    for (seeds) |seed| try agreeAll(seed);
    var prng = std.Random.DefaultPrng.init(0x1de7_7f1e);
    var buf: [160]u8 = undefined;
    for (0..3 * iterations) |_| try agreeAll(randomInput(prng.random(), &buf));
}
