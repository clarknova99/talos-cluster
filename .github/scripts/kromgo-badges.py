import os
import sys
import requests

secret_domain = os.environ.get("SECRET_DOMAIN")

if not secret_domain:
    print("ERROR: SECRET_DOMAIN environment variable is not set!", file=sys.stderr)
    sys.exit(1)
print(f"Using domain: {secret_domain[:3]}...{secret_domain[-3:]}", file=sys.stdout)

def build_kromgo_url(tag: str, base_url: str = secret_domain):
    url = f"https://kromgo.{secret_domain}/{tag}?format=badge&style=flat-square"
    # Print partial URL for debugging (hide most of the domain)
    domain_parts = secret_domain.split('.')
    masked_domain = f"{'*' * len(domain_parts[0])}.{'.'.join(domain_parts[1:])}" if len(domain_parts) > 1 else f"{'*' * len(secret_domain)}"
    print(f"Building kromgo URL for {tag}: https://kromgo.{masked_domain}/{tag}?format=badge&style=flat-square", file=sys.stdout)
    return url


def download_svg(tag: str):
    url = build_kromgo_url(tag)
    
    # Browser-like headers to bypass Cloudflare
    headers = {
        "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.124 Safari/537.36",
        "Accept": "image/svg+xml, */*",
        "Accept-Language": "en-US,en;q=0.9",
        "Accept-Encoding": "gzip, deflate, br",
        "Referer": f"https://kromgo.{secret_domain}/",
        "Cache-Control": "no-cache",
        "Pragma": "no-cache",
        "Sec-Ch-Ua": "\" Not A;Brand\";v=\"99\", \"Chromium\";v=\"91\"",
        "Sec-Ch-Ua-Mobile": "?0"
    }
    
    try:
        response = requests.get(url, headers=headers, timeout=10)
        print(f"Downloaded badge {tag} with status: {response.status_code}", file=sys.stdout)
        
        if response.status_code != 200:
            print(f"Error response content: {response.text[:100]}...", file=sys.stderr)
            return
            
        with open(f"./kromgo/{tag}.svg", "wb") as file_descriptor:
            print(f"Saving badge {tag}", file=sys.stdout)
            for chunk in response:
                file_descriptor.write(chunk)
    except Exception as e:
        print(f"Downloading badge {tag} failed: {str(e)}", file=sys.stderr)


if __name__ == "__main__":

    for tag in [
        "talos_version",
        "kubernetes_version",
        "cluster_age_days",
        "cluster_node_count",
        "cluster_cpu_core_total",        
        "cluster_memory_total",
        "cluster_cpu_usage",
        "cluster_memory_usage"
    ]:
        try:
            download_svg(tag)
        except:
            print(f"Downloading badge {tag} failed.", file=sys.stderr)