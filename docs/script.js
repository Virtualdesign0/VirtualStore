document.documentElement.classList.add("js");

const prefersReducedMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;

const revealItems = document.querySelectorAll(".reveal");
if ("IntersectionObserver" in window) {
	const revealObserver = new IntersectionObserver(
		(entries) => {
			entries.forEach((entry) => {
				if (entry.isIntersecting) {
					entry.target.classList.add("is-visible");
					revealObserver.unobserve(entry.target);
				}
			});
		},
		{ threshold: 0.12 }
	);
	revealItems.forEach((item) => revealObserver.observe(item));
} else {
	revealItems.forEach((item) => item.classList.add("is-visible"));
}

const navLinks = Array.from(document.querySelectorAll(".nav-links a"));
const navSections = navLinks
	.map((link) => document.querySelector(link.getAttribute("href")))
	.filter(Boolean);

if ("IntersectionObserver" in window) {
	const navObserver = new IntersectionObserver(
		(entries) => {
			entries.forEach((entry) => {
				if (!entry.isIntersecting) {
					return;
				}
				navLinks.forEach((link) => {
					link.classList.toggle("is-active", link.getAttribute("href") === `#${entry.target.id}`);
				});
			});
		},
		{ rootMargin: "-35% 0px -58% 0px", threshold: 0 }
	);
	navSections.forEach((section) => navObserver.observe(section));
}

const copyText = async (text) => {
	if (navigator.clipboard && window.isSecureContext) {
		await navigator.clipboard.writeText(text);
		return;
	}
	const textarea = document.createElement("textarea");
	textarea.value = text;
	textarea.setAttribute("readonly", "");
	textarea.style.position = "fixed";
	textarea.style.opacity = "0";
	document.body.appendChild(textarea);
	textarea.select();
	document.execCommand("copy");
	textarea.remove();
};

document.querySelectorAll("[data-copy]").forEach((button) => {
	button.addEventListener("click", async () => {
		const label = button.textContent.trim();
		try {
			await copyText(button.getAttribute("data-copy").replaceAll("\\n", "\n"));
			button.textContent = "Copied";
			button.classList.add("is-copied");
		} catch {
			button.textContent = "Failed";
		}
		window.setTimeout(() => {
			button.textContent = label;
			button.classList.remove("is-copied");
		}, 1400);
	});
});

const apiSearch = document.getElementById("apiSearch");
const apiGroups = Array.from(document.querySelectorAll(".api-group"));
if (apiSearch) {
	apiSearch.addEventListener("input", () => {
		const query = apiSearch.value.trim().toLowerCase();
		apiGroups.forEach((group) => {
			const text = `${group.dataset.search || ""} ${group.textContent}`.toLowerCase();
			group.classList.toggle("is-hidden", query.length > 0 && !text.includes(query));
		});
	});
}

const conceptSearch = document.getElementById("conceptSearch");
const conceptItems = Array.from(document.querySelectorAll(".concept-item"));
if (conceptSearch) {
	conceptSearch.addEventListener("input", () => {
		const query = conceptSearch.value.trim().toLowerCase();
		conceptItems.forEach((item) => {
			const text = `${item.dataset.search || ""} ${item.textContent}`.toLowerCase();
			const matches = query.length === 0 || text.includes(query);
			item.classList.toggle("is-hidden", !matches);
			if (query.length > 0 && matches) {
				item.open = true;
			}
		});
	});
}

const levelButtons = Array.from(document.querySelectorAll("[data-level]"));
const levelPanels = Array.from(document.querySelectorAll("[data-level-panel]"));
levelButtons.forEach((button) => {
	button.addEventListener("click", () => {
		const level = button.getAttribute("data-level");
		levelButtons.forEach((candidate) => {
			candidate.classList.toggle("is-active", candidate === button);
		});
		levelPanels.forEach((panel) => {
			panel.classList.toggle("is-active", panel.getAttribute("data-level-panel") === level);
		});
	});
});

const canvas = document.getElementById("networkCanvas");
const statusText = document.getElementById("visual-status");
const detailText = document.getElementById("visual-detail");

if (canvas) {
	const ctx = canvas.getContext("2d");
	const phases = [
		{
			status: "Claiming player lease",
			detail: "Making sure another server is not still using this profile.",
			accent: "#61d6aa",
			active: "lease",
		},
		{
			status: "Checking a profile change",
			detail: "Invalid changes are discarded before they reach live data.",
			accent: "#76a9d7",
			active: "transaction",
		},
		{
			status: "Saving pending work",
			detail: "A later server can finish this reward if the player leaves.",
			accent: "#e8b85f",
			active: "operation",
		},
		{
			status: "Updating the player's UI",
			detail: "The client receives only the fields approved by the server.",
			accent: "#61d6aa",
			active: "replica",
		},
		{
			status: "Saving before the player leaves",
			detail: "The profile is saved before another server may open it.",
			accent: "#df786f",
			active: "release",
		},
	];

	const nodes = [
		{ id: "server", label: "Game server", sub: "active session", x: 0.67, y: 0.24 },
		{ id: "lease", label: "Lease", sub: "token verified", x: 0.81, y: 0.39 },
		{ id: "record", label: "Player record", sub: "Data + Meta", x: 0.69, y: 0.61 },
		{ id: "operation", label: "Operation", sub: "pending -> receipt", x: 0.84, y: 0.76 },
		{ id: "replica", label: "Owner client", sub: "path patches", x: 0.51, y: 0.78 },
		{ id: "transaction", label: "Transaction", sub: "isolated copy", x: 0.52, y: 0.46 },
		{ id: "release", label: "Release", sub: "save + unlock", x: 0.89, y: 0.18 },
	];

	const edges = [
		["server", "lease"],
		["lease", "record"],
		["server", "transaction"],
		["transaction", "record"],
		["record", "operation"],
		["record", "replica"],
		["record", "release"],
		["release", "lease"],
	];

	let width = 0;
	let height = 0;
	let lastPhaseIndex = -1;

	const resizeCanvas = () => {
		const rect = canvas.getBoundingClientRect();
		const ratio = Math.min(window.devicePixelRatio || 1, 2);
		width = Math.max(320, Math.floor(rect.width));
		height = Math.max(500, Math.floor(rect.height));
		canvas.width = Math.floor(width * ratio);
		canvas.height = Math.floor(height * ratio);
		ctx.setTransform(ratio, 0, 0, ratio, 0, 0);
	};

	const nodePosition = (node) => ({
		x: node.x * width,
		y: node.y * height,
	});

	const roundedRect = (x, y, w, h, r) => {
		const radius = Math.min(r, w / 2, h / 2);
		ctx.beginPath();
		ctx.moveTo(x + radius, y);
		ctx.arcTo(x + w, y, x + w, y + h, radius);
		ctx.arcTo(x + w, y + h, x, y + h, radius);
		ctx.arcTo(x, y + h, x, y, radius);
		ctx.arcTo(x, y, x + w, y, radius);
		ctx.closePath();
	};

	const drawText = (text, x, y, options = {}) => {
		ctx.font = `${options.weight || 700} ${options.size || 12}px Inter, system-ui, sans-serif`;
		ctx.fillStyle = options.color || "#eef3f1";
		ctx.textAlign = options.align || "center";
		ctx.textBaseline = "middle";
		ctx.fillText(text, x, y);
	};

	const draw = (time = 0) => {
		ctx.clearRect(0, 0, width, height);
		const phaseIndex = prefersReducedMotion ? 0 : Math.floor(time / 2500) % phases.length;
		const phase = phases[phaseIndex];
		const progress = prefersReducedMotion ? 0.5 : (time % 2500) / 2500;

		if (phaseIndex !== lastPhaseIndex) {
			statusText.textContent = phase.status;
			detailText.textContent = phase.detail;
			lastPhaseIndex = phaseIndex;
		}

		ctx.save();
		ctx.fillStyle = "rgba(238,243,241,0.018)";
		for (let x = 0; x < width; x += 48) {
			for (let y = 0; y < height; y += 48) {
				ctx.fillRect(x, y, 1, 1);
			}
		}

		edges.forEach(([fromId, toId], index) => {
			const from = nodePosition(nodes.find((node) => node.id === fromId));
			const to = nodePosition(nodes.find((node) => node.id === toId));
			const active = fromId === phase.active || toId === phase.active;
			ctx.beginPath();
			ctx.moveTo(from.x, from.y);
			ctx.lineTo(to.x, to.y);
			ctx.strokeStyle = active ? `${phase.accent}88` : "rgba(228,235,232,0.13)";
			ctx.lineWidth = active ? 1.5 : 1;
			ctx.stroke();

			if (!prefersReducedMotion) {
				const packet = (progress + index * 0.13) % 1;
				const px = from.x + (to.x - from.x) * packet;
				const py = from.y + (to.y - from.y) * packet;
				ctx.beginPath();
				ctx.arc(px, py, active ? 3.5 : 2, 0, Math.PI * 2);
				ctx.fillStyle = active ? phase.accent : "rgba(228,235,232,0.28)";
				ctx.fill();
			}
		});

		nodes.forEach((node, index) => {
			const pos = nodePosition(node);
			const active = node.id === phase.active;
			const drift = prefersReducedMotion ? 0 : Math.sin(time / 900 + index) * 3;
			const w = Math.min(142, width * 0.16);
			const h = 54;
			const x = pos.x - w / 2;
			const y = pos.y - h / 2 + drift;

			ctx.fillStyle = active ? `${phase.accent}18` : "rgba(17,20,22,0.82)";
			ctx.strokeStyle = active ? phase.accent : "rgba(228,235,232,0.18)";
			ctx.lineWidth = active ? 1.5 : 1;
			roundedRect(x, y, w, h, 5);
			ctx.fill();
			ctx.stroke();

			if (active && !prefersReducedMotion) {
				ctx.strokeStyle = `${phase.accent}33`;
				ctx.lineWidth = 8;
				roundedRect(x - 4, y - 4, w + 8, h + 8, 7);
				ctx.stroke();
			}

			drawText(node.label, pos.x, y + 20, { size: 11, weight: 800 });
			drawText(node.sub, pos.x, y + 37, { size: 9, weight: 600, color: active ? phase.accent : "#77837f" });
		});

		ctx.restore();
		if (!prefersReducedMotion) {
			window.requestAnimationFrame(draw);
		}
	};

	const resizeObserver = new ResizeObserver(() => {
		resizeCanvas();
		draw(performance.now());
	});
	resizeObserver.observe(canvas);
	resizeCanvas();
	draw();
}
