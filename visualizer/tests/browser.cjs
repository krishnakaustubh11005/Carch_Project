/* Run with PLAYWRIGHT_PATH pointing at an installed playwright package.
 * Start the viewer first; VIEWER_URL defaults to http://127.0.0.1:8000.
 */
const assert = require('node:assert/strict');
const {chromium} = require(process.env.PLAYWRIGHT_PATH || 'playwright');

(async () => {
    const browser = await chromium.launch({headless:true});
    try {
        const page = await browser.newPage({viewport:{width:1600,height:1100}});
        const errors = [];
        page.on('pageerror',error => errors.push(error.message));
        await page.goto(process.env.VIEWER_URL || 'http://127.0.0.1:8000');
        await page.waitForSelector('[data-node="add_operands"]');
        assert.equal(await page.locator('[data-node="add_carry_in"]').count(),1);
        assert.equal(await page.locator('.node-title', {hasText:'$or'}).count(),1);
        assert.equal(await page.locator('[data-net]').count(),8);

        await page.locator('[data-node="add_operands"]').click();
        assert.match(await page.locator('#inspector').innerText(),/half_adder/);
        const wirePoint = await page.locator('.net-hit').first().evaluate(path => {
            const point = path.getPointAtLength(path.getTotalLength()*.5);
            const screen = new DOMPoint(point.x,point.y).matrixTransform(path.getScreenCTM());
            return {x:screen.x,y:screen.y};
        });
        await page.mouse.click(wirePoint.x,wirePoint.y);
        assert.match(await page.locator('#inspector').innerText(),/Drivers/);
        assert.match(await page.locator('#inspector').innerText(),/Consumers/);
        assert.ok(await page.locator('[data-net].selected').count());
        await page.keyboard.press('Escape');
        assert.equal(await page.locator('.selected').count(),0);

        const getView = () => page.locator('.graph-content').getAttribute('transform');
        const view = await getView();
        await page.locator('#zoom-in').click();
        assert.notEqual(await getView(),view);
        await page.locator('#fit').click();
        assert.equal(await getView(),view);

        // Pointer-centered zoom: the world coordinate under the cursor stays fixed.
        const bounds = await page.locator('svg').boundingBox();
        const parse = text => text.match(/[-+]?\d*\.?\d+(?:e[-+]?\d+)?/g).map(Number);
        const before = parse(await getView());
        const px=120,py=100;
        await page.mouse.move(bounds.x+px,bounds.y+py);
        await page.mouse.wheel(0,-100);
        await page.waitForTimeout(100);
        const after = parse(await getView());
        assert.ok(Math.abs((px-before[0])/before[2]-(px-after[0])/after[2]) < .01);
        assert.ok(Math.abs((py-before[1])/before[2]-(py-after[1])/after[2]) < .01);

        // Pan in screen pixels, independent of scale.
        const panBefore = parse(await getView());
        await page.mouse.move(bounds.x+8,bounds.y+8);
        await page.mouse.down();
        await page.mouse.move(bounds.x+68,bounds.y+48);
        await page.mouse.up();
        const panAfter = parse(await getView());
        assert.ok(Math.abs(panAfter[0]-panBefore[0]-60)<.01);
        assert.ok(Math.abs(panAfter[1]-panBefore[1]-40)<.01);

        await page.locator('#fit').click();
        const parentView = await getView();
        await page.locator('[data-node="add_operands"]').dblclick();
        await page.waitForSelector('.node-title:text-is("$xor")');
        assert.equal(await page.locator('.node-title:text-is("$and")').count(),1);
        await page.locator('[data-level="0"]').click();
        await page.waitForSelector('[data-node="add_operands"]');
        await page.waitForTimeout(50);
        assert.equal(await getView(),parentView);
        await page.screenshot({path:process.env.SCREENSHOT || 'sim/build/visualizer/full-adder.png',fullPage:true});
        await page.route('**/api/build', route => route.fulfill({status:400,contentType:'application/json',body:JSON.stringify({error:'Test elaboration failure'})}));
        await page.locator('#rebuild').click();
        await page.waitForSelector('.build-error');
        assert.match(await page.locator('.build-error').innerText(),/Test elaboration failure/);
        assert.equal(await page.locator('[data-net]').count(),0);
        assert.deepEqual(errors,[]);
        console.log('Browser checks passed: actual adder wiring, trace inspector, zoom, pan, drill-down, return viewport, explicit failed-build state.');
    } finally {
        await browser.close();
    }
})().catch(error => {console.error(error); process.exitCode=1;});
