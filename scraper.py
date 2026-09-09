import pandas as pd
import requests, json
from bs4 import BeautifulSoup
import re
from concurrent.futures import ThreadPoolExecutor, as_completed
import time
import argparse
import os

# =========================
# ARGUMENT PARSER
# =========================
parser = argparse.ArgumentParser(
    description="Travers Competitor Pricing Scraper"
)

parser.add_argument(
    "--input",
    required=True,
    help="Input Excel file path"
)

parser.add_argument(
    "--output",
    required=False,
    help="Output Excel file path (optional)"
)

args = parser.parse_args()

input_file = args.input

if args.output:
    output_file = args.output
else:
    base = os.path.splitext(os.path.basename(input_file))[0]
    output_file = base + "_output.xlsx"

# =========================
# READ INPUT FILE
# =========================
df = pd.read_excel(input_file, dtype=str)



start_time = time.time()

url_prefix = 'https://www.travers.com/catalogsearch/result/?q='

headers = {
    'accept': '*/*',
    'accept-encoding': 'gzip, deflate, br, zstd',
    'accept-language': 'en-GB,en-US;q=0.9,en;q=0.8',
    'connection': 'keep-alive',
    'content-type': 'application/x-www-form-urlencoded',
    'origin': 'https://www.travers.com',
    'referer': 'https://www.travers.com/',
    'user-agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36',
    'x-algolia-api-key': '63e2a5040c7f053f65f54964f1c7746d',
    'x-algolia-application-id': '1HWJVF93ZD'
}

MODEL_KEY_RE = re.compile(r"^model_num_\d+$")


def extract_url_by_sku(hits, sku):

    target = sku

    for item in hits:

        for key, value in item.items():

            if MODEL_KEY_RE.match(key):

                if str(value) == target:
                    return item.get("url")

    return None


ALGOLIA_URL = (
    "https://1hwjvf93zd-dsn.algolia.net/1/indexes/*/queries"
)

print("Total products -----------", len(df))


def brand_matchs(a, b):

    a = a.lower().strip()
    b = b.lower().strip()

    return (
        re.search(rf'\b{re.escape(a)}\b', b) is not None
        or re.search(rf'\b{re.escape(b)}\b', a) is not None
    )


def process_row(index, row):

    sku = str(row.get('MPN', '')).strip()
    title = str(row.get('Product Name', '')).strip()
    brands = str(row.get('Brand', '')).strip()

    product_dict = {
        'MPN': sku,
        'Brand': brands,
        'Input Title': title,
        'Product URL': '-',
        'Product Title': '-',
        'Travers-Strike Price': '-',
        'Travers-Sale Price': '-',
        'Error': ''
    }

    try:

        payload = json.dumps({
            "requests": [
                {
                    "indexName": "may_production_default_products_sku_sort",
                    "params": f"query={sku}&page=0"
                }
            ]
        })

        try:

            resp = requests.post(
                ALGOLIA_URL,
                data=payload,
                headers=headers,
                timeout=20
            )

        except requests.exceptions.ConnectionError as e:

            product_dict['Error'] = str(e)
            return product_dict

        print(
            f"------------ {index + 1} out of "
            f"{len(df)} {sku} {resp.status_code} ---------"
        )

        if resp.status_code != 200:

            print(
                f"Algolia request failed for SKU "
                f"{sku} with status code {resp.status_code}"
            )

            product_dict['Error'] = (
                f"Algolia status {resp.status_code}"
            )

            return product_dict

        resp_json = resp.json()

        hits = resp_json.get(
            "results",
            [{}]
        )[0].get("hits", [])

        products = None

        if hits:
            products = extract_url_by_sku(hits, sku)

        if not products:

            product_dict['Error'] = "No product URL found"
            return product_dict

        product_url = products

        product_dict['Product URL'] = product_url

        r2 = requests.get(product_url, timeout=20)

        print(f"------------ {sku} {r2.status_code} ---------")

        if r2.status_code != 200:

            product_dict['Error'] = (
                f"Product page status {r2.status_code}"
            )

            return product_dict

        soup = BeautifulSoup(r2.content, 'html.parser')
        model_datas = []
        model_data = soup.select("tr.text-sm")
        for row in model_data:
            if row.select_one('th').get_text(strip=True) == 'Model #':
                model_datas.append(row.select_one('td').get_text(strip=True))

        # model_datas = re.findall(
        #     r'{"label":"Model #","value":"(.*)","code":"model_num_1851"}',
        #     r2.text
        # )

        brand_datas = re.findall(
            r'"item_brand":"(.*)","quantity"',
            r2.text
        )
        # brand_datas = re.findall(
        #     r'{"label":"Brand","value":"(.*)","code":"brand_123"}',
        #     r2.text
        # )

        sku_match = (
            True
            if sku.lower() == next(
                (d.lower() for d in model_datas),
                None
            )
            else False
        )

        brand_name = next((d for d in brand_datas), None)

        brand_match = (
            brand_matchs(brands, brand_name)
            if brands and brand_name
            else False
        )

        if not (sku_match and brand_match):

            product_dict['Error'] = "SKU / Brand mismatch"
            return product_dict

        prices = list(set([
            p.text.replace("$",'').strip()
            for p in soup.select(
                '[itemprop="offers"] .price, '
                '.manufacturer_price .price,'
                '.catalog_price .price'
            )
        ]))

        title_tag = soup.select_one(
            '.mobile-product-title h1'
        )

        if title_tag:
            product_dict['Product Title'] = (
                title_tag.text.strip()
            )

        if len(prices) == 1:

            product_dict['Travers-Sale Price'] = prices[0]

        elif len(prices) >= 2:
            prices = [float(x.replace(',', '').replace('$', '')) for x in prices if x]
            product_dict['Travers-Strike Price'] = max(prices)
            product_dict['Travers-Sale Price'] = min(prices)

        print(product_dict)

    except Exception as e:

        product_dict['Error'] = str(e)

    return product_dict


product_list = []

try:

    with ThreadPoolExecutor(max_workers=2) as executor:

        futures = [
            executor.submit(process_row, index, row)
            for index, row in df.iterrows()
        ]

        for future in as_completed(futures):

            try:

                product_list.append(future.result())

            except Exception as e:

                product_list.append({
                    'MPN': '',
                    'Brand': '',
                    'Input Title': '',
                    'Product URL': '-',
                    'Product Title': '-',
                    'Travers-Strike Price': '-',
                    'Travers-Sale Price': '-',
                    'Error': f"Thread error: {e}"
                })

finally:

    output_df = pd.DataFrame(product_list)

    output_df.to_excel(output_file, index=False)

    print(f"\n✅ Data saved safely in '{output_file}'")

end_time = time.time()

print(f"--- {end_time - start_time:.2f} seconds ---")