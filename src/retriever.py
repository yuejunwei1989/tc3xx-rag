"""双路检索器：向量相似度 + 关键词精确匹配"""

from __future__ import annotations

import json
import re
from dataclasses import dataclass

from src.config import RetrievalConfig
from src.embedder import EmbedderProtocol
from src.store import VectorStore, FTSStore


@dataclass
class SearchResult:
    chunk_id: str
    content: str
    context_chain: str
    element_type: str
    page: int
    doc_id: str
    score: float
    source: str  # "vector" | "keyword" | "both"
    related_images: list[dict]
    expanded_context: list[dict]


class Retriever:
    def __init__(
        self,
        config: RetrievalConfig,
        embedder: EmbedderProtocol,
        vector_store: VectorStore,
        fts_store: FTSStore,
    ):
        self.config = config
        self.embedder = embedder
        self.vector_store = vector_store
        self.fts_store = fts_store

    def search(
        self, query: str, top_k: int = None, doc_filter: str = None
    ) -> list[SearchResult]:
        top_k = top_k or self.config.top_k
        keywords = self._extract_keywords(query)

        # 向量检索
        query_embedding = self.embedder.embed([query])[0]
        vector_results = self.vector_store.search(
            query_embedding, top_k=top_k * 2, doc_filter=doc_filter
        )

        # 关键词检索
        kw_results = []
        if keywords:
            kw_results = self.fts_store.search(
                keywords, top_k=top_k * 2, doc_filter=doc_filter
            )

        # 融合（候选放宽到 rerank_candidates 以便精排）
        merged = self._merge(
            vector_results, kw_results,
            self.config.rerank_candidates if self.config.rerank_url else top_k,
        )
        return self._rerank(query, merged)[:top_k] if self.config.rerank_url else merged

    def _rerank(self, query: str, results: list[SearchResult]) -> list[SearchResult]:
        """调用 Infinity /rerank (bge-reranker-v2-m3) 做交叉编码精排。失败则回退原序。"""
        if len(results) <= 1:
            return results
        try:
            import httpx
            resp = httpx.post(
                self.config.rerank_url,
                json={
                    "query": query,
                    "documents": [r.content[:4000] for r in results],
                    "return_documents": False,
                },
                timeout=10.0,
            )
            resp.raise_for_status()
            scores = resp.json().get("results", [])
            # Infinity 返回 [{index, relevance_score}, ...]
            for item in scores:
                idx = item.get("index")
                if idx is not None and 0 <= idx < len(results):
                    results[idx].score = float(item.get("relevance_score", 0.0))
            return sorted(results, key=lambda r: r.score, reverse=True)
        except Exception:
            return results  # 精排服务不可用时静默回退，不阻塞检索

    def _extract_keywords(self, query: str) -> list[str]:
        # 勘误/缺陷编号: FlexRay_AI.103, DMA_TC.067, GETH_TC.H003, ADC_TC.086
        # 必须先于 compound 匹配，否则会被截成 FlexRay_AI 丢掉序号
        errata_id = r'\b[A-Za-z][A-Za-z0-9]*(?:_[A-Za-z0-9]+)+\.[A-Z]?\d+\b'
        # 带下划线的复合寄存器名优先匹配: SPI_CR1, GPIO_ODR, RCC_APB2ENR
        compound = r'\b[A-Z][A-Z0-9]*(?:_[A-Z0-9]+)+\b'
        # 时序参数: tSU, tHD, tWR, tLOW, tHIGH, tAA, tDH
        timing = r'\bt[A-Z][A-Z0-9.]*\b'
        # 2+ 字符的全大写词: TMOD, TCON, SPI, T2CON, TH0, IE, IP
        single = r'\b[A-Z][A-Z0-9]+\b'
        # iLLD 驼峰 API 名: IfxCan_Can_setBaudrate, IfxQspi_SpiMaster_initModule
        # 旧规则只认全大写，导致这类查询提取不到任何关键词、只能走向量召回
        camel_api = r'\bIfx[A-Za-z0-9]*(?:_[A-Za-z0-9]+)+\b'
        matches = re.findall(f"{errata_id}|{compound}|{timing}|{single}|{camel_api}", query)
        domain_terms = [
            "时序", "波形", "应答", "非应答", "应答查询",
            "起始", "停止", "字节写", "页写", "写周期",
            "当前地址读", "随机读", "顺序读", "读操作", "写操作",
            "建立时间", "保持时间",
        ]
        matches.extend(term for term in domain_terms if term in query)
        matches.extend(self._semantic_aliases(query))
        return list(dict.fromkeys(matches))

    def _semantic_aliases(self, query: str) -> list[str]:
        alias_map = {
            "时序": ["timing"],
            "波形": ["waveform"],
            "应答": ["ACK", "acknowledge"],
            "非应答": ["NACK", "no acknowledge"],
            "应答查询": ["ACK", "ACK polling"],
            "起始": ["START", "START condition"],
            "停止": ["STOP", "STOP condition"],
            "字节写": ["byte write"],
            "页写": ["page write"],
            "写周期": ["write cycle", "tWR"],
            "当前地址读": ["current address read"],
            "随机读": ["random read"],
            "顺序读": ["sequential read"],
            "建立时间": ["setup time", "tSU"],
            "保持时间": ["hold time", "tHD"],
        }
        aliases = []
        for term, values in alias_map.items():
            if term in query:
                aliases.extend(values)
        return aliases

    def _merge(
        self, vector_results: list[dict], kw_results: list[dict], top_k: int
    ) -> list[SearchResult]:
        seen: set[str] = set()
        results: list[SearchResult] = []

        kw_ids = {r["chunk_id"] for r in kw_results}

        if self.config.keyword_priority:
            for r in kw_results:
                if r["chunk_id"] not in seen:
                    seen.add(r["chunk_id"])
                    results.append(self._to_result(r, "keyword"))

        for r in vector_results:
            if r["chunk_id"] not in seen:
                seen.add(r["chunk_id"])
                source = "both" if r["chunk_id"] in kw_ids else "vector"
                results.append(self._to_result(r, source))

        return results[:top_k]

    def _to_result(self, raw: dict, source: str) -> SearchResult:
        meta = raw.get("metadata", {})
        return SearchResult(
            chunk_id=raw["chunk_id"],
            content=raw["content"],
            context_chain=meta.get("context_chain", ""),
            element_type=meta.get("element_type", "text"),
            page=meta.get("page", 0),
            doc_id=meta.get("doc_id", ""),
            score=1.0 - raw.get("distance", 0.0),
            source=source,
            related_images=self._parse_related_images(meta.get("related_images", "[]")),
            expanded_context=self._expanded_context(meta, raw["chunk_id"]),
        )

    def _parse_related_images(self, value) -> list[dict]:
        if isinstance(value, list):
            return value
        if not value:
            return []
        try:
            data = json.loads(value)
        except (TypeError, json.JSONDecodeError):
            return []
        return data if isinstance(data, list) else []

    def _expanded_context(self, meta: dict, chunk_id: str) -> list[dict]:
        if not self.config.context_expand:
            return []

        doc_id = meta.get("doc_id", "")
        page = int(meta.get("page", 0) or 0)
        context_chain = meta.get("context_chain", "")
        if not doc_id:
            return []

        nearby = self.fts_store.fetch_context(
            doc_id=doc_id,
            page=page,
            context_chain=context_chain,
            radius=1,
            limit=6,
        )
        expanded = []
        for item in nearby:
            if item["chunk_id"] == chunk_id:
                continue
            item_meta = item.get("metadata", {})
            expanded.append({
                "chunk_id": item["chunk_id"],
                "content": item["content"],
                "context_chain": item_meta.get("context_chain", ""),
                "element_type": item_meta.get("element_type", ""),
                "page": item_meta.get("page", 0),
                "related_images": self._parse_related_images(
                    item_meta.get("related_images", "[]")
                ),
            })
        return expanded
