# Skill: Peer Review

## When to use

When a PDF is uploaded in **#research-paper-peer-review**, or when the user explicitly asks
for a peer review of a paper by upload.

## Steps

1. **Run the review script** on the uploaded PDF:
   ```
   exec: python3 ~/argo-shim-lite/tools/review_pdf.py {{MediaPath}}
   ```
   The script splits the PDF into size-safe chunks, sends each natively to Claude Opus 4.7
   via the Argo API (preserving equations and figures), and synthesizes a structured review.

2. **Relay the output verbatim** to the channel. Do not paraphrase or truncate.

3. **Invite drill-down** — after posting the review, ask:
   "Want me to dig deeper into the methodology, a specific section, or the experimental results?"

## Evaluation lens

Reviews are always done from the HPC/parallel computing perspective:
- **Scalability:** Weak-scaling vs strong-scaling? Are claims substantiated with curves?
- **Portability:** CUDA-only vs Kokkos/SYCL/HIP/ROCm?
- **Reproducibility:** Is the experimental setup precise enough to reproduce?
- **Rigor:** Are baselines fair? Is statistical variance reported?

## Format rules

- Relay the script output as-is — it is already Discord-scannable with bullets and headers
- Do not send a prose summary first; the script output is the summary
- Follow-up questions are answered from context — no need to re-run the script
