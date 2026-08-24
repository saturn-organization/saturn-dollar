// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {TimelockController} from "openzeppelin-contracts/contracts/governance/TimelockController.sol";

import {USDat} from "../src/USDat.sol";
import {UpgradeUSDatBase} from "./UpgradeUSDatBase.sol";

/**
 * @notice Step 2 of the M→PYUSDX migration finalizer: execute the scheduled `setAssetCap(M_TOKEN, 0)`
 *         once its 5-day delay has matured. EXECUTOR_ROLE on the asset-cap-manager timelock is held by
 *         address(0), so any EOA can broadcast this.
 *
 *         WARNING: zeroing the cap is irreversible without another timelocked `setAssetCap`, and it disables
 *         M `replaceAsset` and `claimMYield` too. To avoid stranding M, this script reverts before
 *         broadcasting if any M backing remains (assetBalanceOf(M) != 0), and warns to sweep unclaimed M
 *         yield via `claimMYield` first.
 */
contract ExecuteZeroMAssetCap is Script, UpgradeUSDatBase {
    function run() public {
        TimelockController timelock = TimelockController(payable(ASSET_CAP_TIMELOCK));

        bytes memory payload = _buildZeroMAssetCapData();
        bytes32 id = timelock.hashOperation(USDAT_PROXY, 0, payload, PREDECESSOR, SALT);

        console.log("Operation id:");
        console.logBytes32(id);

        require(timelock.isOperationReady(id), "operation not ready: never scheduled or delay pending");

        // Zeroing the cap disables M `replaceAsset`, so any M still registered as backing could never be
        // drained again — it would be permanently stranded. Refuse to finalize while backing remains.
        uint256 trackedM = USDat(USDAT_PROXY).assetBalanceOf(M_TOKEN);
        console.log("M tracked backing (assetBalanceOf):", trackedM);

        require(trackedM == 0, "M backing not drained: run replaceAsset until assetBalanceOf(M) == 0");

        // Unclaimed M yield (held M above the drained backing) also becomes unclaimable once the cap is zero,
        // since `claimMYield` needs isAllowedAsset(M). It can't be forced to zero — M keeps earning — so this
        // is a warning, not a gate: sweep it with `claimMYield` immediately before executing.
        uint256 unclaimedMYield = IERC20(M_TOKEN).balanceOf(USDAT_PROXY);
        console.log("Unclaimed M yield stranded if not swept:", unclaimedMYield);

        if (unclaimedMYield != 0) {
            console.log("WARNING: call claimMYield() to sweep M yield before finalizing.");
        }

        vm.startBroadcast();

        timelock.execute(USDAT_PROXY, 0, payload, PREDECESSOR, SALT);

        vm.stopBroadcast();

        console.log("M asset cap set to 0: isAllowedAsset(M) is now false; M wraps are permanently disabled.");
    }
}
