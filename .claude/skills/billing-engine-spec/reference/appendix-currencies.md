# Appendix: accepted currencies

> Licence note: this appendix describes observable behaviour of lago-api (AGPL-3.0) at pin `591ae90`. It is a
> behavioural specification, not source code; read `reimplementation-kit/reference/legal-and-provenance.md` before
> using it for a proprietary rebuild.

<!-- evidence-check: off normative spec; evidence = the domain.money.currency_exponent.* vectors (exponent, subunit and accepted flag of sample codes, checked by kitrun against the oracle) -->

The engine accepts exactly the 142 ISO 4217 codes below for every currency-bearing attribute (organization and
billing-entity default currency, customer currency, plan, add-on, coupon, applied coupon, fee, credit, wallet). Any
other code is a validation error on that attribute (`value_is_invalid`). The **exponent** is the number of decimal
digits an amount keeps (`*_cents` integers are amounts in units of 10^-exponent); **minor units** is the number of
`*_cents` units per major unit. The table is the engine's money table, which differs from the current ISO list in
places (BE-DM-21, BE-DM-22):

- **HUF** keeps no minor unit (exponent 0) although ISO 4217 lists two decimals: forint amounts are whole numbers.
  **MGA** also has exponent 0 (its historical sub-unit is one fifth). [vec: domain.money.currency_exponent.005]
- **MRO** (the pre-2018 ouguiya code) has a minor unit of one fifth: exponent 1 but 5 minor units per major unit, the only
  accepted currency where minor units ≠ 10^exponent. Conversions that multiply a rounded amount by "minor units per
  major unit" can produce non-integer minor amounts for it; a rebuild should reject MRO or treat it explicitly
  (no vector exercises MRO arithmetic). [vec: domain.money.currency_exponent.006]
- Valid ISO codes missing from the table (for example OMR, or MRU, the successor of MRO) are rejected.
  [vec: domain.money.currency_exponent.007]

| Code | Name | Exponent | Minor units |
|---|---|---|---|
| AED | United Arab Emirates Dirham | 2 | 100 |
| AFN | Afghan Afghani | 2 | 100 |
| ALL | Albanian Lek | 2 | 100 |
| AMD | Armenian Dram | 2 | 100 |
| ANG | Netherlands Antillean Gulden | 2 | 100 |
| AOA | Angolan Kwanza | 2 | 100 |
| ARS | Argentine Peso | 2 | 100 |
| AUD | Australian Dollar | 2 | 100 |
| AWG | Aruban Florin | 2 | 100 |
| AZN | Azerbaijani Manat | 2 | 100 |
| BAM | Bosnia and Herzegovina Convertible Mark | 2 | 100 |
| BBD | Barbadian Dollar | 2 | 100 |
| BDT | Bangladeshi Taka | 2 | 100 |
| BGN | Bulgarian Lev | 2 | 100 |
| BHD | Bahraini Dinar | 3 | 1000 |
| BIF | Burundian Franc | 0 | 1 |
| BMD | Bermudian Dollar | 2 | 100 |
| BND | Brunei Dollar | 2 | 100 |
| BOB | Bolivian Boliviano | 2 | 100 |
| BRL | Brazilian Real | 2 | 100 |
| BSD | Bahamian Dollar | 2 | 100 |
| BWP | Botswana Pula | 2 | 100 |
| BYN | Belarusian Ruble | 2 | 100 |
| BZD | Belize Dollar | 2 | 100 |
| CAD | Canadian Dollar | 2 | 100 |
| CDF | Congolese Franc | 2 | 100 |
| CHF | Swiss Franc | 2 | 100 |
| CLF | Unidad de Fomento | 4 | 10000 |
| CLP | Chilean Peso | 0 | 1 |
| CNY | Chinese Renminbi Yuan | 2 | 100 |
| COP | Colombian Peso | 2 | 100 |
| CRC | Costa Rican Colón | 2 | 100 |
| CVE | Cape Verdean Escudo | 2 | 100 |
| CZK | Czech Koruna | 2 | 100 |
| DJF | Djiboutian Franc | 0 | 1 |
| DKK | Danish Krone | 2 | 100 |
| DOP | Dominican Peso | 2 | 100 |
| DZD | Algerian Dinar | 2 | 100 |
| EGP | Egyptian Pound | 2 | 100 |
| ETB | Ethiopian Birr | 2 | 100 |
| EUR | Euro | 2 | 100 |
| FJD | Fijian Dollar | 2 | 100 |
| FKP | Falkland Pound | 2 | 100 |
| GBP | British Pound | 2 | 100 |
| GEL | Georgian Lari | 2 | 100 |
| GHS | Ghanaian Cedi | 2 | 100 |
| GIP | Gibraltar Pound | 2 | 100 |
| GMD | Gambian Dalasi | 2 | 100 |
| GNF | Guinean Franc | 0 | 1 |
| GTQ | Guatemalan Quetzal | 2 | 100 |
| GYD | Guyanese Dollar | 2 | 100 |
| HKD | Hong Kong Dollar | 2 | 100 |
| HNL | Honduran Lempira | 2 | 100 |
| HRK | Croatian Kuna | 2 | 100 |
| HTG | Haitian Gourde | 2 | 100 |
| HUF | Hungarian Forint | 0 | 1 |
| IDR | Indonesian Rupiah | 2 | 100 |
| ILS | Israeli New Shekel | 2 | 100 |
| INR | Indian Rupee | 2 | 100 |
| IRR | Iranian Rial | 2 | 100 |
| ISK | Icelandic Króna | 0 | 1 |
| JMD | Jamaican Dollar | 2 | 100 |
| JOD | Jordanian Dinar | 3 | 1000 |
| JPY | Japanese Yen | 0 | 1 |
| KES | Kenyan Shilling | 2 | 100 |
| KGS | Kyrgyzstani Som | 2 | 100 |
| KHR | Cambodian Riel | 2 | 100 |
| KMF | Comorian Franc | 0 | 1 |
| KRW | South Korean Won | 0 | 1 |
| KWD | Kuwaiti Dinar | 3 | 1000 |
| KYD | Cayman Islands Dollar | 2 | 100 |
| KZT | Kazakhstani Tenge | 2 | 100 |
| LAK | Lao Kip | 2 | 100 |
| LBP | Lebanese Pound | 2 | 100 |
| LKR | Sri Lankan Rupee | 2 | 100 |
| LRD | Liberian Dollar | 2 | 100 |
| LSL | Lesotho Loti | 2 | 100 |
| MAD | Moroccan Dirham | 2 | 100 |
| MDL | Moldovan Leu | 2 | 100 |
| MGA | Malagasy Ariary | 0 | 1 |
| MKD | Macedonian Denar | 2 | 100 |
| MMK | Myanmar Kyat | 2 | 100 |
| MNT | Mongolian Tögrög | 2 | 100 |
| MOP | Macanese Pataca | 2 | 100 |
| MRO | Mauritanian Ouguiya | 1 | 5 |
| MUR | Mauritian Rupee | 2 | 100 |
| MVR | Maldivian Rufiyaa | 2 | 100 |
| MWK | Malawian Kwacha | 2 | 100 |
| MXN | Mexican Peso | 2 | 100 |
| MYR | Malaysian Ringgit | 2 | 100 |
| MZN | Mozambican Metical | 2 | 100 |
| NAD | Namibian Dollar | 2 | 100 |
| NGN | Nigerian Naira | 2 | 100 |
| NIO | Nicaraguan Córdoba | 2 | 100 |
| NOK | Norwegian Krone | 2 | 100 |
| NPR | Nepalese Rupee | 2 | 100 |
| NZD | New Zealand Dollar | 2 | 100 |
| PAB | Panamanian Balboa | 2 | 100 |
| PEN | Peruvian Sol | 2 | 100 |
| PGK | Papua New Guinean Kina | 2 | 100 |
| PHP | Philippine Peso | 2 | 100 |
| PKR | Pakistani Rupee | 2 | 100 |
| PLN | Polish Złoty | 2 | 100 |
| PYG | Paraguayan Guaraní | 0 | 1 |
| QAR | Qatari Riyal | 2 | 100 |
| RON | Romanian Leu | 2 | 100 |
| RSD | Serbian Dinar | 2 | 100 |
| RUB | Russian Ruble | 2 | 100 |
| RWF | Rwandan Franc | 0 | 1 |
| SAR | Saudi Riyal | 2 | 100 |
| SBD | Solomon Islands Dollar | 2 | 100 |
| SCR | Seychellois Rupee | 2 | 100 |
| SEK | Swedish Krona | 2 | 100 |
| SGD | Singapore Dollar | 2 | 100 |
| SHP | Saint Helenian Pound | 2 | 100 |
| SLL | Sierra Leonean Leone | 2 | 100 |
| SOS | Somali Shilling | 2 | 100 |
| SRD | Surinamese Dollar | 2 | 100 |
| STD | São Tomé and Príncipe Dobra | 2 | 100 |
| SZL | Swazi Lilangeni | 2 | 100 |
| THB | Thai Baht | 2 | 100 |
| TJS | Tajikistani Somoni | 2 | 100 |
| TOP | Tongan Paʻanga | 2 | 100 |
| TRY | Turkish Lira | 2 | 100 |
| TTD | Trinidad and Tobago Dollar | 2 | 100 |
| TWD | New Taiwan Dollar | 2 | 100 |
| TZS | Tanzanian Shilling | 2 | 100 |
| UAH | Ukrainian Hryvnia | 2 | 100 |
| UGX | Ugandan Shilling | 0 | 1 |
| USD | United States Dollar | 2 | 100 |
| UYU | Uruguayan Peso | 2 | 100 |
| UZS | Uzbekistan Som | 2 | 100 |
| VND | Vietnamese Đồng | 0 | 1 |
| VUV | Vanuatu Vatu | 0 | 1 |
| WST | Samoan Tala | 2 | 100 |
| XAF | Central African Cfa Franc | 0 | 1 |
| XCD | East Caribbean Dollar | 2 | 100 |
| XOF | West African Cfa Franc | 0 | 1 |
| XPF | Cfp Franc | 0 | 1 |
| YER | Yemeni Rial | 2 | 100 |
| ZAR | South African Rand | 2 | 100 |
| ZMW | Zambian Kwacha | 2 | 100 |

Summary: 18 codes with exponent 0, 1 codes with exponent 1, 119 codes with exponent 2, 3 codes with exponent 3, 1 codes with exponent 4; 142 codes in total.

## Provenance (maintainers)

- Accepted list: `$API/app/models/concerns/currencies.rb:6` @591ae90 (142 entries). Exponents and minor units: the
  money library of the pinned bundle as configured by the application, dumped on 2026-10-02 with the oracle toolchain
  (ruby-4.0.6, `Money::Currency` for each accepted code). Sample codes re-executed through the oracle op
  `domain.currency_exponent` (kitrun 2026-10-02, all PASS).
- Update trigger: a pin bump that changes the accepted list or the money library version; re-dump and diff.
