/* Netlist connectivity and layout are separate: ELK never invents connections. */
const content = document.querySelector('#content');
const list = document.querySelector('#module-list');
const search = document.querySelector('#search');
const esc = value => String(value).replace(/[&<>"']/g, char => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[char]));
let sources = [], design = null, current = null, hierarchy = [], serial = 0;
let camera = null;

function renderList() {
    list.innerHTML = sources.filter(module => module.name.toLowerCase().includes(search.value.toLowerCase()))
        .map(module => `<button class="module-link ${module.name === design?.top ? 'active' : ''}" data-top="${esc(module.name)}"><span>${esc(module.name)}</span><span class="kind">TOP</span></button>`).join('');
    list.querySelectorAll('[data-top]').forEach(button => button.onclick = () => rebuild(button.dataset.top));
}

async function rebuild(top = 'full_adder') {
    const token = ++serial;
    content.innerHTML = `<div class="loading">Elaborating ${esc(top)}…</div>`;
    try {
        if (typeof ELK === 'undefined') throw new Error('Layout engine missing. Run npm ci --prefix visualizer, then reload.');
        const response = await fetch('/api/build', {method:'POST', headers:{'Content-Type':'application/json'}, body:JSON.stringify({top})});
        const result = await response.json();
        if (!response.ok) throw new Error(result.error || 'Build failed');
        if (token !== serial) return;
        design = result;
        hierarchy = [{type:design.top, path:design.top}];
        renderList();
        await showModule();
    } catch (error) {
        if (token !== serial) return;
        content.innerHTML = `<h1>Build unavailable</h1><pre class="build-error">${esc(error.message)}</pre><button id="retry">Retry build</button>`;
        document.querySelector('#retry').onclick = () => rebuild(top);
    }
}

// Netlist port bit indices are ordered LSB first. Every endpoint gets its own ID.
const endpointId = endpoint => JSON.stringify([endpoint.node, endpoint.port, endpoint.index]);
function toLayout(module) {
    const children = [], edges = [], endpoints = new Map();
    function node(id, title, subtitle, ports, childType = null, boundary = false) {
        const counts = {WEST:0, EAST:0};
        const layoutPorts = [];
        for (const port of ports) {
            const side = boundary ? (port.direction === 'input' ? 'EAST' : 'WEST') : (port.direction === 'output' ? 'EAST' : 'WEST');
            port.bits.forEach((bit, index) => {
                const key = endpointId({node:boundary ? '$boundary' : id, port:port.name, index});
                const bitIndex = (port.offset || 0) + (port.upto ? port.bits.length-1-index : index);
                const label = port.bits.length > 1 ? `${port.name}[${bitIndex}]` : port.name;
                const pin = {id:key, width:6, height:6, label, bit,
                    layoutOptions:{'elk.port.side':side, 'elk.port.index':String(counts[side]++)}};
                endpoints.set(key, pin);
                layoutPorts.push(pin);
            });
        }
        children.push({id, width:boundary ? 120 : 220,
            height:Math.max(boundary ? 50 : 100, 70 + Math.max(counts.WEST,counts.EAST)*23),
            title, subtitle, childType, boundary, ports:layoutPorts,
            layoutOptions:{'elk.portConstraints':'FIXED_ORDER', ...(boundary ? {'elk.layered.layering.layerConstraint':ports[0].direction === 'input' ? 'FIRST' : 'LAST'} : {})}});
    }
    for (const port of module.ports) node(`@port:${port.name}`, port.name, `${port.direction} · ${port.bits.length} bit${port.bits.length === 1 ? '' : 's'}`, [port], null, true);
    for (const cell of module.cells) node(cell.id, cell.type, cell.id, cell.ports, cell.module);
    let number = 0;
    for (const net of module.nets) {
        let drivers = net.drivers.map(endpointId);
        if (net.constant && net.consumers.length) {
            const id = `@constant:${net.id}`;
            const pinId = `${id}:out`;
            children.push({id, title:`1'b${net.bit}`, subtitle:'constant', width:80, height:45, boundary:true,
                ports:[{id:pinId, width:6, height:6, label:'', layoutOptions:{'elk.port.side':'EAST'}}],
                layoutOptions:{'elk.portConstraints':'FIXED_SIDE'}});
            drivers = [pinId];
        }
        for (const driver of drivers) {
            for (const consumer of net.consumers.map(endpointId)) {
                if (driver !== consumer) edges.push({id:`edge${number++}`, sources:[driver], targets:[consumer], net:net.id});
            }
        }
    }
    if (children.length > 500 || edges.length > 5000) throw new Error('This module exceeds the first-release layout limit (500 blocks / 5000 bit connections). Select a smaller top. Bus bundling and large-array layout are planned.');
    return {id:'root', children, edges, layoutOptions:{
        'elk.algorithm':'layered', 'elk.direction':'RIGHT', 'elk.edgeRouting':'ORTHOGONAL',
        'elk.spacing.nodeNode':'65', 'elk.layered.spacing.nodeNodeBetweenLayers':'120',
        'elk.spacing.portsSurrounding':'[top=55,left=0,bottom=25,right=0]',
        'elk.padding':'[top=40,left=40,bottom=40,right=40]',
    }};
}

async function showModule(savedView = null) {
    const token = ++serial;
    const entry = hierarchy.at(-1);
    current = design.modules[entry.type];
    document.querySelector('#crumb-module').textContent = entry.path;
    content.innerHTML = `<div class="loading">Routing ${esc(entry.path)}…</div>`;
    try {
        const graph = await new ELK().layout(toLayout(current));
        if (token !== serial) return;
        content.innerHTML = `<div class="module-heading"><div><div class="eyebrow">ELABORATED RTL SCHEMATIC</div><h1>${esc(entry.type)}</h1><div class="source">${esc(current.source)}</div></div><button id="rebuild">Rebuild design</button></div>
            <div class="hierarchy-trail">${hierarchy.map((item,index) => `<button data-level="${index}">${esc(item.path.split('/').at(-1))}</button>`).join('<span> / </span>')}</div>
            <div class="graph-toolbar"><span>Scroll to zoom · drag to pan · click a wire to trace · double-click a module to enter</span><div><button id="zoom-out">−</button><button id="zoom-in">+</button><button id="fit">Fit</button></div></div>
            <div class="schematic-workspace"><div class="graph-viewport"><svg class="hierarchy" aria-label="Elaborated module connectivity"><g class="graph-content"></g></svg></div><aside id="inspector"><h3>Inspect the datapath</h3><p>Select a wire or block.</p><p>Wires use netlist bit identities. Crossings are not junctions; selecting a net highlights all its branches.</p><p>Current release draws bus bits individually, not bundled.</p></aside></div>
            <div class="source build-meta">${esc(design.representation)} · Artifacts: ${esc(design.artifacts)}</div>`;
        renderGraph(graph);
        setupCamera(graph, savedView);
        document.querySelector('#rebuild').onclick = () => rebuild(design.top);
        content.querySelectorAll('[data-level]').forEach(button => button.onclick = () => {
            hierarchy.at(-1).view = camera.state();
            hierarchy = hierarchy.slice(0,Number(button.dataset.level)+1);
            showModule(hierarchy.at(-1).view);
        });
    } catch (error) {
        if (token === serial) content.innerHTML = `<pre class="build-error">${esc(error.message)}</pre>`;
    }
}

function renderGraph(graph) {
    const group = content.querySelector('.graph-content');
    const paths = (graph.edges || []).map(edge => (edge.sections || []).map(section => {
        const points = [section.startPoint, ...(section.bendPoints || []), section.endPoint];
        const d = points.map((point,index) => `${index ? 'L' : 'M'}${point.x} ${point.y}`).join(' ');
        const net = current.nets.find(net => net.id === edge.net);
        const segmentIndex = points.findIndex((point,index) => index < points.length-1 && Math.abs(point.y-points[index+1].y) < 1 && Math.abs(point.x-points[index+1].x) > 85);
        const label = segmentIndex >= 0 ? `<text class="net-label" x="${(points[segmentIndex].x+points[segmentIndex+1].x)/2}" y="${points[segmentIndex].y-7}">${esc(net.label)}</text>` : '';
        return `<g data-net="${esc(edge.net)}"><path class="net" d="${d}"/><path class="net-hit" d="${d}"/>${label}</g>`;
    }).join('')).join('');
    const nodes = graph.children.map(node => `<g class="node" data-node="${esc(node.id)}">
        <rect class="node-body" x="${node.x}" y="${node.y}" width="${node.width}" height="${node.height}" rx="7"/>
        <text class="node-title" x="${node.x+12}" y="${node.y+22}">${esc(node.title)}</text>
        <text class="node-kicker" x="${node.x+12}" y="${node.y+39}">${esc(node.subtitle.length > 28 ? node.subtitle.slice(0,25)+'…' : node.subtitle)}</text>
        ${node.ports.map(port => {
            const right = port.x > node.width/2;
            const x = node.x+port.x+port.width/2, y = node.y+port.y+port.height/2;
            return `<circle class="node-pin ${right ? 'output' : 'input'}" cx="${x}" cy="${y}" r="3"/><text class="pin-label" text-anchor="${right ? 'end' : 'start'}" x="${x+(right ? -10 : 10)}" y="${y+3}">${esc(port.label)}</text>`;
        }).join('')}
        ${node.childType ? `<text class="node-action" x="${node.x+12}" y="${node.y+node.height-9}">DOUBLE-CLICK TO ENTER ↗</text>` : ''}
        <title>${esc(node.subtitle)} : ${esc(node.title)}</title></g>`).join('');
    group.innerHTML = paths + nodes;
    content.querySelectorAll('[data-net]').forEach(element => element.addEventListener('click', event => {
        event.stopPropagation(); selectNet(element.dataset.net);
    }));
    content.querySelectorAll('[data-node]').forEach(element => {
        element.addEventListener('click', () => selectNode(element.dataset.node));
        element.addEventListener('dblclick', () => {
            const cell = current.cells.find(cell => cell.id === element.dataset.node);
            if (!cell?.module) return;
            hierarchy.at(-1).view = camera.state();
            hierarchy.push({type:cell.module,path:`${hierarchy.at(-1).path}/${cell.id}`});
            showModule();
        });
    });
}

function clearSelection() {
    content.querySelectorAll('.selected').forEach(element => element.classList.remove('selected'));
    content.querySelectorAll('.tracing').forEach(element => element.classList.remove('tracing'));
}
function selectNet(id) {
    clearSelection();
    const net = current.nets.find(net => net.id === id);
    content.querySelector('.graph-content').classList.add('tracing');
    content.querySelectorAll('[data-net]').forEach(element => element.classList.toggle('selected',element.dataset.net === id));
    const endpointList = items => items.length ? items.map(item => `<li>${esc(item.node === '$boundary' ? 'Module port' : item.node)}.${esc(item.port)} [bit ${item.index}]</li>`).join('') : '<li>None recorded</li>';
    document.querySelector('#inspector').innerHTML = `<h3>${esc(net.label)}</h3><p>1 bit · ${esc(net.id)}${net.constant ? ' · constant' : ''}</p><h4>Names / aliases</h4><ul>${net.aliases.map(alias => `<li>${esc(alias)}</li>`).join('')}</ul><h4>Drivers</h4><ul>${net.constant ? `<li>Constant 1'b${esc(net.bit)}</li>` : ''}${endpointList(net.drivers)}</ul><h4>Consumers</h4><ul>${endpointList(net.consumers)}</ul>`;
}
function selectNode(id) {
    clearSelection();
    const cell = current.cells.find(cell => cell.id === id);
    content.querySelectorAll('[data-node]').forEach(element => element.classList.toggle('selected',element.dataset.node === id));
    document.querySelector('#inspector').innerHTML = cell ? `<h3>${esc(cell.type)}</h3><p>${esc(hierarchy.at(-1).path)}/${esc(cell.id)}</p><p>${esc(cell.source)}</p><h4>Ports</h4><ul>${cell.ports.map(port => `<li>${esc(port.direction)} ${esc(port.name)} · ${port.bits.length} bits</li>`).join('')}</ul>${cell.module ? '<p>Double-click the block to enter its internal schematic.</p>' : '<p>Primitive logic cell. Connectivity is preserved even when no special symbol exists.</p>'}` : '<h3>Module boundary / constant</h3><p>Click its wire to inspect connectivity.</p>';
}

function setupCamera(graph, saved) {
    const svg = content.querySelector('svg');
    const group = svg.querySelector('.graph-content');
    let state = saved ? {...saved} : {x:0,y:0,scale:1};
    let drag = null;
    const apply = () => group.setAttribute('transform',`translate(${state.x} ${state.y}) scale(${state.scale})`);
    const fit = () => {
        const box = svg.getBoundingClientRect();
        state.scale = Math.min((box.width-40)/graph.width,(box.height-40)/graph.height,1.5);
        state.x = (box.width-graph.width*state.scale)/2;
        state.y = (box.height-graph.height*state.scale)/2;
        apply();
    };
    const zoom = (factor,x,y) => {
        const next = Math.max(.02,Math.min(8,state.scale*factor));
        const ratio = next/state.scale;
        state.x = x-(x-state.x)*ratio; state.y = y-(y-state.y)*ratio;
        state.scale = next; apply();
    };
    svg.addEventListener('wheel',event => {
        event.preventDefault();
        const box = svg.getBoundingClientRect();
        zoom(Math.exp(-event.deltaY*.002),event.clientX-box.left,event.clientY-box.top);
    },{passive:false});
    svg.addEventListener('pointerdown',event => {
        if (event.target.closest('[data-node], [data-net]') || event.button !== 0) return;
        drag = {x:event.clientX,y:event.clientY,tx:state.x,ty:state.y};
        svg.setPointerCapture(event.pointerId);
    });
    svg.addEventListener('pointermove',event => {
        if (!drag) return;
        state.x = drag.tx+event.clientX-drag.x; state.y = drag.ty+event.clientY-drag.y; apply();
    });
    for (const type of ['pointerup','pointercancel','lostpointercapture']) svg.addEventListener(type,() => {drag=null;});
    document.querySelector('#fit').onclick = fit;
    for (const [id,factor] of [['zoom-in',1.25],['zoom-out',.8]]) document.querySelector(`#${id}`).onclick = () => {
        const box = svg.getBoundingClientRect(); zoom(factor,box.width/2,box.height/2);
    };
    camera = {state:() => ({...state})};
    requestAnimationFrame(() => saved ? apply() : fit());
}

document.addEventListener('keydown',event => {if (event.key === 'Escape') clearSelection();});
search.addEventListener('input',renderList);
fetch('/api/modules').then(response => response.json()).then(data => {
    sources=data; renderList();
    document.querySelector('#module-count').textContent=`${data.length} MODULES`;
    rebuild('full_adder');
}).catch(error => {content.innerHTML=`<pre class="build-error">${esc(error.message)}</pre>`;});
