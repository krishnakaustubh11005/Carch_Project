// Verification helpers only; this file contains no synthesizable hardware.
integer checks;
integer errors;

task init_checks;
    begin
        checks = 0;
        errors = 0;
    end
endtask

task fail_check;
    input [639:0] message;
    begin
        errors = errors + 1;
        if (errors <= 10)
            $display("Mismatch at check %0d: %0s", checks, message);
    end
endtask

task finish_checks;
    begin
        if (checks == 0)
            fail_check("no test cases executed");
        $display("Checks: %0d, errors: %0d", checks, errors);
        if (errors == 0)
            $display("TEST PASSED");
        else
            $display("TEST FAILED");
        $finish;
    end
endtask

task finish_checks_strict;
    begin
        if (checks == 0)
            fail_check("no test cases executed");
        $display("Checks: %0d, errors: %0d", checks, errors);
        if (errors != 0) begin
            $display("TEST FAILED");
            $fatal(1, "Verification failed");
        end
        $display("TEST PASSED");
        $finish;
    end
endtask

function integer ceil_log2;
    input integer value;
    integer remaining;
    begin
        remaining = value - 1;
        ceil_log2 = 0;
        while (remaining > 0) begin
            remaining = remaining >> 1;
            ceil_log2 = ceil_log2 + 1;
        end
    end
endfunction
