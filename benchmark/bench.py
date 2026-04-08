"""
vLLM Benchmark Tool - InferenceX-style metrics.

Measures: TTFT, ITL, Output Tokens/s, Input Tokens/s, Throughput,
          Request Latency, and Cost per Million Tokens.
"""

from __future__ import annotations

import argparse
import asyncio
import json
import statistics
import sys
import time
from dataclasses import dataclass, field

import aiohttp


# --------------- Azure Spot pricing (USD/hour, East US) ---------------
SPOT_PRICING = {
    "Standard_NC24ads_A100_v4": {"spot": 0.678, "ondemand": 3.673, "gpus": 1},
    "Standard_NC48ads_A100_v4": {"spot": 1.358, "ondemand": 7.346, "gpus": 2},
    "Standard_NC96ads_A100_v4": {"spot": 2.715, "ondemand": 14.692, "gpus": 4},
    "Standard_ND96asr_v4": {"spot": 3.366, "ondemand": 27.197, "gpus": 8},
    "Standard_ND96amsr_A100_v4": {"spot": 4.234, "ondemand": 32.770, "gpus": 8},
}


@dataclass
class RequestResult:
    """Result of a single benchmark request."""

    ttft_ms: float = 0.0
    itl_ms: list[float] = field(default_factory=list)
    total_latency_ms: float = 0.0
    input_tokens: int = 0
    output_tokens: int = 0
    success: bool = True
    error: str = ""


@dataclass
class BenchmarkReport:
    """Aggregated benchmark report."""

    model: str
    vm_size: str
    concurrency: int
    num_requests: int
    input_seq_len: int
    output_seq_len: int

    # Latency
    ttft_p50_ms: float = 0.0
    ttft_p90_ms: float = 0.0
    ttft_p99_ms: float = 0.0
    ttft_avg_ms: float = 0.0

    itl_p50_ms: float = 0.0
    itl_p90_ms: float = 0.0
    itl_p99_ms: float = 0.0
    itl_avg_ms: float = 0.0

    # Throughput
    output_tokens_per_sec: float = 0.0
    input_tokens_per_sec: float = 0.0
    requests_per_sec: float = 0.0
    total_tokens_per_sec: float = 0.0

    # Totals
    total_input_tokens: int = 0
    total_output_tokens: int = 0
    total_duration_sec: float = 0.0
    successful_requests: int = 0
    failed_requests: int = 0

    # Cost
    spot_cost_per_hour: float = 0.0
    ondemand_cost_per_hour: float = 0.0
    spot_cost_per_1m_tokens: float = 0.0
    ondemand_cost_per_1m_tokens: float = 0.0
    spot_savings_pct: float = 0.0


def percentile(data: list[float], p: float) -> float:
    if not data:
        return 0.0
    sorted_data = sorted(data)
    k = (len(sorted_data) - 1) * (p / 100.0)
    f = int(k)
    c = f + 1
    if c >= len(sorted_data):
        return sorted_data[f]
    return sorted_data[f] + (k - f) * (sorted_data[c] - sorted_data[f])


def build_prompt(token_count: int) -> str:
    """Build a prompt that approximates token_count input tokens."""
    # ~1 token per 4 chars for English text
    word = "benchmark "
    repeats = max(1, (token_count * 4) // len(word))
    return word * repeats


async def send_request_streaming(
    session: aiohttp.ClientSession,
    url: str,
    model: str,
    prompt: str,
    max_tokens: int,
    api_key: str | None,
) -> RequestResult:
    """Send a single streaming request and measure TTFT + ITL."""
    result = RequestResult()
    headers = {"Content-Type": "application/json"}
    if api_key:
        headers["Authorization"] = f"Bearer {api_key}"

    payload = {
        "model": model,
        "prompt": prompt,
        "max_tokens": max_tokens,
        "stream": True,
        "temperature": 0.0,
    }

    start = time.perf_counter()
    first_token_time = None
    last_token_time = start
    token_count = 0

    try:
        async with session.post(
            f"{url}/v1/completions", json=payload, headers=headers
        ) as resp:
            if resp.status != 200:
                body = await resp.text()
                result.success = False
                result.error = f"HTTP {resp.status}: {body[:200]}"
                return result

            async for line in resp.content:
                decoded = line.decode("utf-8").strip()
                if not decoded.startswith("data: "):
                    continue
                data_str = decoded[6:]
                if data_str == "[DONE]":
                    break

                now = time.perf_counter()
                try:
                    chunk = json.loads(data_str)
                except json.JSONDecodeError:
                    continue

                choices = chunk.get("choices", [])
                if not choices:
                    continue

                text = choices[0].get("text", "")
                if not text:
                    continue

                token_count += 1

                if first_token_time is None:
                    first_token_time = now
                    result.ttft_ms = (first_token_time - start) * 1000
                else:
                    itl = (now - last_token_time) * 1000
                    result.itl_ms.append(itl)

                last_token_time = now

    except Exception as e:
        result.success = False
        result.error = str(e)
        return result

    end = time.perf_counter()
    result.total_latency_ms = (end - start) * 1000
    result.output_tokens = token_count
    # Approximate input tokens from prompt length
    result.input_tokens = max(1, len(prompt) // 4)

    return result


async def run_benchmark(
    url: str,
    model: str,
    concurrency: int,
    num_requests: int,
    input_seq_len: int,
    output_seq_len: int,
    api_key: str | None,
) -> list[RequestResult]:
    """Run concurrent benchmark requests."""
    prompt = build_prompt(input_seq_len)
    semaphore = asyncio.Semaphore(concurrency)
    results: list[RequestResult] = []

    async def worker():
        async with semaphore:
            async with aiohttp.ClientSession(
                timeout=aiohttp.ClientTimeout(total=600)
            ) as session:
                r = await send_request_streaming(
                    session, url, model, prompt, output_seq_len, api_key
                )
                results.append(r)

    tasks = [asyncio.create_task(worker()) for _ in range(num_requests)]
    await asyncio.gather(*tasks)
    return results


def compute_report(
    results: list[RequestResult],
    model: str,
    vm_size: str,
    concurrency: int,
    input_seq_len: int,
    output_seq_len: int,
    total_duration: float,
    num_gpus: int,
) -> BenchmarkReport:
    """Compute aggregated metrics from individual results."""
    successful = [r for r in results if r.success]
    failed = [r for r in results if not r.success]

    report = BenchmarkReport(
        model=model,
        vm_size=vm_size,
        concurrency=concurrency,
        num_requests=len(results),
        input_seq_len=input_seq_len,
        output_seq_len=output_seq_len,
        successful_requests=len(successful),
        failed_requests=len(failed),
        total_duration_sec=total_duration,
    )

    if not successful:
        return report

    # TTFT
    ttfts = [r.ttft_ms for r in successful if r.ttft_ms > 0]
    if ttfts:
        report.ttft_avg_ms = statistics.mean(ttfts)
        report.ttft_p50_ms = percentile(ttfts, 50)
        report.ttft_p90_ms = percentile(ttfts, 90)
        report.ttft_p99_ms = percentile(ttfts, 99)

    # ITL
    all_itls = [itl for r in successful for itl in r.itl_ms]
    if all_itls:
        report.itl_avg_ms = statistics.mean(all_itls)
        report.itl_p50_ms = percentile(all_itls, 50)
        report.itl_p90_ms = percentile(all_itls, 90)
        report.itl_p99_ms = percentile(all_itls, 99)

    # Token counts
    report.total_input_tokens = sum(r.input_tokens for r in successful)
    report.total_output_tokens = sum(r.output_tokens for r in successful)

    # Throughput
    if total_duration > 0:
        report.output_tokens_per_sec = report.total_output_tokens / total_duration
        report.input_tokens_per_sec = report.total_input_tokens / total_duration
        report.total_tokens_per_sec = (
            report.total_input_tokens + report.total_output_tokens
        ) / total_duration
        report.requests_per_sec = len(successful) / total_duration

    # Cost calculation
    pricing = SPOT_PRICING.get(vm_size)
    if pricing:
        nodes = max(1, num_gpus // pricing["gpus"]) if pricing["gpus"] > 0 else 1
        report.spot_cost_per_hour = pricing["spot"] * nodes
        report.ondemand_cost_per_hour = pricing["ondemand"] * nodes

        if report.total_tokens_per_sec > 0:
            tokens_per_hour = report.total_tokens_per_sec * 3600
            report.spot_cost_per_1m_tokens = (
                report.spot_cost_per_hour / tokens_per_hour
            ) * 1_000_000
            report.ondemand_cost_per_1m_tokens = (
                report.ondemand_cost_per_hour / tokens_per_hour
            ) * 1_000_000

        report.spot_savings_pct = round(
            (1 - pricing["spot"] / pricing["ondemand"]) * 100, 1
        )

    return report


def print_report(report: BenchmarkReport) -> None:
    """Print the benchmark report in InferenceX-style format."""
    W = 60

    print("\n" + "=" * W)
    print(" vLLM BENCHMARK REPORT (InferenceX-style)")
    print("=" * W)

    print(f"\n{'Model:':<30} {report.model}")
    print(f"{'VM Size:':<30} {report.vm_size}")
    print(f"{'Concurrency:':<30} {report.concurrency}")
    print(f"{'Requests:':<30} {report.successful_requests}/{report.num_requests}")
    print(f"{'ISL (input seq len):':<30} {report.input_seq_len}")
    print(f"{'OSL (output seq len):':<30} {report.output_seq_len}")
    print(f"{'Total Duration:':<30} {report.total_duration_sec:.2f}s")

    print(f"\n{'─' * W}")
    print(" LATENCY")
    print(f"{'─' * W}")
    print(f"  {'Metric':<25} {'Avg':>8} {'P50':>8} {'P90':>8} {'P99':>8}")
    print(f"  {'TTFT (ms)':<25} {report.ttft_avg_ms:>8.1f} {report.ttft_p50_ms:>8.1f} {report.ttft_p90_ms:>8.1f} {report.ttft_p99_ms:>8.1f}")
    print(f"  {'ITL (ms)':<25} {report.itl_avg_ms:>8.1f} {report.itl_p50_ms:>8.1f} {report.itl_p90_ms:>8.1f} {report.itl_p99_ms:>8.1f}")

    print(f"\n{'─' * W}")
    print(" THROUGHPUT")
    print(f"{'─' * W}")
    print(f"  {'Output Tokens/s:':<30} {report.output_tokens_per_sec:>10.1f}")
    print(f"  {'Input Tokens/s:':<30} {report.input_tokens_per_sec:>10.1f}")
    print(f"  {'Total Tokens/s:':<30} {report.total_tokens_per_sec:>10.1f}")
    print(f"  {'Requests/s:':<30} {report.requests_per_sec:>10.2f}")

    print(f"\n{'─' * W}")
    print(" COST (Azure Spot vs On-Demand)")
    print(f"{'─' * W}")
    print(f"  {'Spot $/hour:':<30} ${report.spot_cost_per_hour:>9.3f}")
    print(f"  {'On-Demand $/hour:':<30} ${report.ondemand_cost_per_hour:>9.3f}")
    print(f"  {'Spot savings:':<30} {report.spot_savings_pct:>9.1f}%")
    print(f"  {'Spot $/1M tokens:':<30} ${report.spot_cost_per_1m_tokens:>9.4f}")
    print(f"  {'On-Demand $/1M tokens:':<30} ${report.ondemand_cost_per_1m_tokens:>9.4f}")

    print(f"\n{'=' * W}\n")


def export_json(report: BenchmarkReport, path: str) -> None:
    """Export report as JSON."""
    data = {
        "config": {
            "model": report.model,
            "vm_size": report.vm_size,
            "concurrency": report.concurrency,
            "num_requests": report.num_requests,
            "input_seq_len": report.input_seq_len,
            "output_seq_len": report.output_seq_len,
        },
        "latency": {
            "ttft_ms": {
                "avg": round(report.ttft_avg_ms, 2),
                "p50": round(report.ttft_p50_ms, 2),
                "p90": round(report.ttft_p90_ms, 2),
                "p99": round(report.ttft_p99_ms, 2),
            },
            "itl_ms": {
                "avg": round(report.itl_avg_ms, 2),
                "p50": round(report.itl_p50_ms, 2),
                "p90": round(report.itl_p90_ms, 2),
                "p99": round(report.itl_p99_ms, 2),
            },
        },
        "throughput": {
            "output_tokens_per_sec": round(report.output_tokens_per_sec, 2),
            "input_tokens_per_sec": round(report.input_tokens_per_sec, 2),
            "total_tokens_per_sec": round(report.total_tokens_per_sec, 2),
            "requests_per_sec": round(report.requests_per_sec, 4),
        },
        "cost": {
            "spot_cost_per_hour": round(report.spot_cost_per_hour, 3),
            "ondemand_cost_per_hour": round(report.ondemand_cost_per_hour, 3),
            "spot_cost_per_1m_tokens": round(report.spot_cost_per_1m_tokens, 4),
            "ondemand_cost_per_1m_tokens": round(report.ondemand_cost_per_1m_tokens, 4),
            "spot_savings_pct": report.spot_savings_pct,
        },
        "totals": {
            "total_input_tokens": report.total_input_tokens,
            "total_output_tokens": report.total_output_tokens,
            "total_duration_sec": round(report.total_duration_sec, 2),
            "successful_requests": report.successful_requests,
            "failed_requests": report.failed_requests,
        },
    }
    with open(path, "w") as f:
        json.dump(data, f, indent=2)
    print(f"Report exported to {path}")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="vLLM Benchmark Tool - InferenceX-style metrics",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    parser.add_argument(
        "--url",
        default="http://localhost:8000",
        help="vLLM server URL",
    )
    parser.add_argument(
        "--model",
        default="Qwen/Qwen3.5-122B-A10B",
        help="Model name served by vLLM",
    )
    parser.add_argument(
        "--vm-size",
        default="Standard_ND96amsr_A100_v4",
        choices=list(SPOT_PRICING.keys()),
        help="Azure VM size (for cost calculation)",
    )
    parser.add_argument(
        "--num-gpus",
        type=int,
        default=8,
        help="Number of GPUs used (for cost calculation)",
    )
    parser.add_argument(
        "--concurrency",
        type=int,
        nargs="+",
        default=[1, 4, 16, 32],
        help="Concurrency levels to test",
    )
    parser.add_argument(
        "--num-requests",
        type=int,
        default=32,
        help="Total requests per concurrency level",
    )
    parser.add_argument(
        "--isl",
        type=int,
        default=512,
        help="Input Sequence Length (approximate token count)",
    )
    parser.add_argument(
        "--osl",
        type=int,
        default=128,
        help="Output Sequence Length (max_tokens)",
    )
    parser.add_argument(
        "--api-key",
        default=None,
        help="API key for vLLM server",
    )
    parser.add_argument(
        "--output",
        default=None,
        help="Path to export JSON report",
    )
    parser.add_argument(
        "--warmup",
        type=int,
        default=2,
        help="Number of warmup requests before benchmarking",
    )
    return parser.parse_args()


async def warmup(url: str, model: str, api_key: str | None, count: int) -> None:
    """Send warmup requests to avoid cold-start effects."""
    print(f"Sending {count} warmup requests...")
    async with aiohttp.ClientSession(
        timeout=aiohttp.ClientTimeout(total=300)
    ) as session:
        for _ in range(count):
            await send_request_streaming(
                session, url, model, "Hello", 8, api_key
            )
    print("Warmup complete.\n")


async def main() -> None:
    args = parse_args()

    # Health check
    try:
        async with aiohttp.ClientSession(
            timeout=aiohttp.ClientTimeout(total=10)
        ) as session:
            async with session.get(f"{args.url}/health") as resp:
                if resp.status != 200:
                    print(f"ERROR: vLLM health check failed (HTTP {resp.status})")
                    sys.exit(1)
    except Exception as e:
        print(f"ERROR: Cannot reach vLLM at {args.url}: {e}")
        sys.exit(1)

    print("=" * 60)
    print(" vLLM BENCHMARK (InferenceX-style)")
    print("=" * 60)
    print(f"  URL:       {args.url}")
    print(f"  Model:     {args.model}")
    print(f"  VM:        {args.vm_size}")
    print(f"  ISL:       {args.isl}")
    print(f"  OSL:       {args.osl}")
    print(f"  Requests:  {args.num_requests} per concurrency level")
    print(f"  Levels:    {args.concurrency}")
    print()

    # Warmup
    if args.warmup > 0:
        await warmup(args.url, args.model, args.api_key, args.warmup)

    all_reports: list[BenchmarkReport] = []

    for c in args.concurrency:
        print(f"Running benchmark with concurrency={c}...")
        start = time.perf_counter()

        results = await run_benchmark(
            url=args.url,
            model=args.model,
            concurrency=c,
            num_requests=args.num_requests,
            input_seq_len=args.isl,
            output_seq_len=args.osl,
            api_key=args.api_key,
        )

        duration = time.perf_counter() - start

        report = compute_report(
            results=results,
            model=args.model,
            vm_size=args.vm_size,
            concurrency=c,
            input_seq_len=args.isl,
            output_seq_len=args.osl,
            total_duration=duration,
            num_gpus=args.num_gpus,
        )

        print_report(report)
        all_reports.append(report)

        # Errors summary
        failed = [r for r in results if not r.success]
        if failed:
            print(f"  Errors ({len(failed)}):")
            for r in failed[:3]:
                print(f"    - {r.error[:120]}")
            if len(failed) > 3:
                print(f"    ... and {len(failed) - 3} more")

    # Summary table
    print("\n" + "=" * 80)
    print(" SUMMARY ACROSS CONCURRENCY LEVELS")
    print("=" * 80)
    print(
        f"  {'Conc':>5} {'Out tok/s':>10} {'TTFT p50':>10} {'TTFT p99':>10} "
        f"{'ITL p50':>10} {'Req/s':>8} {'Spot $/1Mt':>12}"
    )
    print(f"  {'─' * 5} {'─' * 10} {'─' * 10} {'─' * 10} {'─' * 10} {'─' * 8} {'─' * 12}")
    for r in all_reports:
        print(
            f"  {r.concurrency:>5} {r.output_tokens_per_sec:>10.1f} "
            f"{r.ttft_p50_ms:>10.1f} {r.ttft_p99_ms:>10.1f} "
            f"{r.itl_p50_ms:>10.1f} {r.requests_per_sec:>8.2f} "
            f"${r.spot_cost_per_1m_tokens:>11.4f}"
        )
    print()

    # Export JSON
    if args.output:
        # Export last (highest concurrency) report
        export_json(all_reports[-1], args.output)


if __name__ == "__main__":
    asyncio.run(main())
