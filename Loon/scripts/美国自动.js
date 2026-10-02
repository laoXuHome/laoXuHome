
var POLICY = "美国自动";
var TEST_URL = "https://www.google.com/generate_204";
var TIMEOUT = 1500;
var MAX_NODES = 60;
var WAIT = 1200;
console.log("开始全局优选故障检测");
var current = $config.getSelectedPolicy(POLICY);
console.log("当前节点: " + current);
function testNode(node, callback) {
    console.log("测试: " + node);
    var start = Date.now();
    $httpClient.get({
        url: TEST_URL,
        timeout: TIMEOUT,
        node: node
    }, function(error, response, data) {
        var cost = Date.now() - start;
        if (!error && response && response.status == 204) {
            console.log("可用: " + node + " | " + cost + "ms");
            callback(true, cost);
        } else {
            console.log("失败: " + node + " | " + cost + "ms");
            callback(false, cost);
        }
    });
}
$config.getSubPolicies(POLICY, function(text) {
    var nodes = JSON.parse(text);
    var list = [];
    for (var i = 0; i < nodes.length; i++) {
        if (nodes[i].name != current) {
            list.push(nodes[i].name);
        }
    }
    console.log("备用节点数量: " + list.length);
    testNode(current, function(ok) {
        if (ok) {
            console.log("当前节点正常");
            console.log("不切换");
            $done();
            return;
        }
        console.log("当前节点不可用");
        console.log("开始60节点并行测试");
        var count = Math.min(list.length, MAX_NODES);
        var finished = 0;
        var successNodes = [];
        var successCosts = [];
        for (var i = 0; i < count; i++) {
            (function(node) {
                testNode(node, function(ok, cost) {
                    finished++;
                    if (ok) {
                        successNodes.push(node);
                        successCosts.push(cost);
                    }
                    if (finished == count) {
                        console.log("并行节点测试完成");
                        console.log(
                            "可用节点数量: " +
                            successNodes.length
                        );
                        if (successNodes.length == 0) {
                            console.log("没有找到可用节点");
                            $done();
                            return;
                        }
                        tryNext(0);
                    }
                });
            })(list[i]);
        }
        function tryNext(tried) {
            if (tried >= successNodes.length) {
                console.log("所有可用节点验证失败");
                $done();
                return;
            }
            var fastestIndex = -1;
            var fastestCost = 999999;
            for (var j = 0; j < successNodes.length; j++) {
                if (successNodes[j] == "") {
                    continue;
                }
                if (successCosts[j] < fastestCost) {
                    fastestCost = successCosts[j];
                    fastestIndex = j;
                }
            }
            if (fastestIndex < 0) {
                console.log("没有更多候选节点");
                $done();
                return;
            }
            var node = successNodes[fastestIndex];
            successNodes[fastestIndex] = "";
            console.log(
                "选择最快节点: " +
                node +
                " | " +
                fastestCost +
                "ms"
            );
            console.log("准备切换: " + node);
            var changed = $config.setSelectPolicy(
                POLICY,
                node
            );
            if (!changed) {
                console.log("切换失败: " + node);
                tryNext(tried + 1);
                return;
            }
            console.log("已经切换: " + node);
            setTimeout(function() {
                console.log("验证切换后的节点");
                testNode(node, function(verified) {
                    if (verified) {
                        console.log("节点验证成功");
                        console.log("自动切换完成");
                        $done();
                        return;
                    }
                    console.log("节点验证失败: " + node);
                    tryNext(tried + 1);
                });
            }, WAIT);
        }
    });
});
